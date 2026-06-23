import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // MARK: - Broader context (window scrollback, screen OCR, clipboard, style)

    // Walk the focused window's AX subtree collecting visible text. For chat apps
    // this captures the conversation above the input box; for editors, the document.
    func windowText(limit: Int) -> String {
        guard let element = focusedElement() else { return "" }
        var rootRef: CFTypeRef?
        let root: AXUIElement
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &rootRef) == .success, let r = rootRef {
            root = (r as! AXUIElement)
        } else { root = element }

        var collected: [String] = []
        var seen = Set<String>()
        var budget = 6000
        func walk(_ el: AXUIElement, depth: Int) {
            if depth > 14 || budget <= 0 { return }
            for attr in [kAXValueAttribute, kAXTitleAttribute] {
                var vRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &vRef) == .success,
                   let s = vRef as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count >= 2, t.count <= 2000, !seen.contains(t), !isNumericChrome(t) {
                        seen.insert(t)
                        collected.append(t)
                        budget -= t.count
                    }
                }
            }
            var cRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &cRef) == .success,
               let kids = cRef as? [AXUIElement] {
                for k in kids { if budget <= 0 { break }; walk(k, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        // Text nearest the input (typically last in reading order) is most relevant.
        return String(collected.joined(separator: "\n").suffix(limit))
    }

    // Short labels that are just a number/percentage (zoom "100%", "12", "3.5k", a
    // progress readout). Harmless as UI, but as prompt context they teach the base model
    // to emit bare percentages — keep them out of both the AX walk and OCR.
    func isNumericChrome(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 12 else { return false }
        if !t.contains(where: { $0.isNumber }) { return false }
        let lettery = t.filter { $0.isLetter }.count
        return lettery <= 1 || t.hasSuffix("%")
    }

    func clipboardText(limit: Int, relevantTo context: String) -> String {
        let pb = NSPasteboard.general
        // Skip clipboard content password managers mark concealed/transient — never
        // feed a copied password/secret into the prompt or logs.
        let types = pb.types?.map { $0.rawValue } ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") {
            return ""
        }
        guard let s = pb.string(forType: .string) else { return "" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return "" }
        // Relevance: only fold the clipboard into the prompt if it's a short snippet
        // OR shares a meaningful word with what the user is currently writing. Stops
        // unrelated copied blobs from steering completions.
        if t.count > 60 {
            let ctxWords = Set(context.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
            let shares = t.lowercased().split { !$0.isLetter }.map(String.init).contains { $0.count >= 4 && ctxWords.contains($0) }
            guard shares else { return "" }
        }
        return String(t.prefix(limit))
    }

    // Capture the frontmost app's largest on-screen window via ScreenCaptureKit
    // (the modern replacement for the now-unavailable CGWindowListCreateImage).
    // Returns the image plus the window's screen frame (Quartz, top-left global),
    // which is needed to map OCR coordinates back to the screen.
    // `frontPID` is snapshotted on the main thread by the caller (NSWorkspace is
    // main-thread-affine). A class box carries the Task's result across the
    // semaphore so there's no write-after-return race on a local var.
    final class CaptureBox { var value: (image: CGImage, frame: CGRect, title: String)? }
    // `clip` (global, top-left Quartz coords) captures only that sub-rect of the window
    // instead of the whole thing — used by the caret locator to grab a thin band around
    // the caret line, which cuts both the capture and the downstream OCR cost by ~10x.
    // `scale` downsamples the captured pixels (1.0 = native); Vision cost scales with
    // pixel count, so 0.5 is ~4x cheaper OCR with no accuracy loss for body text.
    // The returned `frame` is the region actually captured (global, top-left), so OCR
    // box coordinates always map back to the screen correctly.
    func captureFocusedWindow(frontPID: pid_t?, clip: CGRect? = nil, scale: CGFloat = 1.0)
        -> (image: CGImage, frame: CGRect, title: String)? {
        guard #available(macOS 14.0, *) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        let box = CaptureBox()
        Task {
            defer { sem.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let windows = content.windows.filter {
                $0.isOnScreen && $0.frame.width > 80 && $0.frame.height > 40 &&
                $0.owningApplication?.processID == frontPID
            }
            guard let win = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.showsCursor = false
            // Resolve the captured region (window-local for sourceRect, global for the
            // returned frame). A clip is intersected with the window; an empty/degenerate
            // intersection falls back to the whole window.
            var captured = win.frame
            if let clip {
                let local = clip.intersection(win.frame)
                if local.width >= 8, local.height >= 8 {
                    config.sourceRect = CGRect(x: local.minX - win.frame.minX, y: local.minY - win.frame.minY,
                                               width: local.width, height: local.height)
                    captured = local
                }
            }
            let s = max(0.25, min(1.0, scale))
            config.width = max(8, Int(captured.width * s))
            config.height = max(8, Int(captured.height * s))
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                box.value = (img, captured, win.title ?? "")
            }
        }
        // Only read box.value if the Task actually finished (semaphore = happens-after).
        return sem.wait(timeout: .now() + 1.5) == .success ? box.value : nil
    }

    func screenOCR(limit: Int, frontPID: pid_t?) -> String {
        guard CGPreflightScreenCaptureAccess() else { return "" }
        // Half-resolution capture: Vision cost scales with pixel count, so this is ~4x
        // cheaper OCR. Body text survives downscaling; only sub-pixel chrome is lost,
        // which minimumTextHeight skips anyway.
        guard let cap = captureFocusedWindow(frontPID: frontPID, scale: 0.5), cap.image.width > 8, cap.image.height > 8 else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate          // far fewer "8nd"/"htttsngtab" misreads
        req.usesLanguageCorrection = true
        req.minimumTextHeight = 0.012             // skip tiny UI chrome (badges, status counters)
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return "" }
        var lines: [String] = []
        for o in obs {
            guard let cand = o.topCandidates(1).first, cand.confidence >= 0.5 else { continue }
            if isLikelyText(cand.string) { lines.append(cand.string) }
        }
        return String(lines.joined(separator: "\n").suffix(limit))
    }

    // Heuristic gate to keep OCR garbage (UI chrome, misreads, glyph soup) out of the
    // prompt: require mostly letters/spaces, at least one real word, and reject lines
    // dominated by digits/percent signs (zoom "100%", counters, progress, prices) — that
    // numeric chrome is exactly what made completions spit out spurious percentages.
    func isLikelyText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 4 else { return false }
        let letters = t.filter { $0.isLetter || $0.isWhitespace }.count
        guard Double(letters) / Double(t.count) >= 0.75 else { return false }
        if t.contains("%") { return false }   // a percentage anywhere reads as a stat/chrome line
        let digits = t.filter { $0.isNumber }.count
        if Double(digits) / Double(t.count) >= 0.2 { return false }
        return t.split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 3 }
    }

    // Screenshot-based caret locator for apps that don't expose AXBoundsForRange
    // (Electron, terminals, custom editors). Captures the focused window, OCRs it,
    // finds where the user's most-recently-typed text ends on screen, and returns
    // the caret rect there. Slow (~150ms), so callers must throttle/cache it.
    // Focused element's global rect in Quartz (top-left origin) coords — the space
    // SCStreamConfiguration.sourceRect / CGEvent use. Read on the main thread (AX is
    // main-affine), so the caret locator can capture just this element's band.
    func focusedElementQuartzRect() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width > 4, size.height > 4 else { return nil }
        return CGRect(origin: point, size: size)
    }

    func screenshotCaretRect(needle: String, frontPID: pid_t?, clip: CGRect?, primaryMaxY: CGFloat) -> (rect: CGRect, charWidth: CGFloat)? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        // `needle`, `frontPID`, `clip` and `primaryMaxY` are all snapshotted on the main
        // thread by the caller — never read self.buffer / NSWorkspace / AX / NSScreen
        // here (off-main). The Quartz→AppKit flip uses the passed-in primaryMaxY for the
        // same reason (NSScreen is main-affine), so we don't call axRectToAppKit here.
        guard needle.count >= 3 else { return nil }
        // Capture only the caret band (clip): a ~10x smaller image than the old
        // full-window grab, so both the capture and the Vision pass are far cheaper.
        // Keep scale 1.0 here (the band is already tiny) so the typed-tail match stays
        // reliable; boundingBox is normalized, so the screen mapping is scale-agnostic.
        guard let cap = captureFocusedWindow(frontPID: frontPID, clip: clip, scale: 1.0), cap.image.width > 8 else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast              // matching a typed tail needs speed, not perfect glyphs
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return nil }

        // Find the observation that ends with our typed tail. Prefer the lowest one
        // on screen (largest 1-minY), since that's usually the active input line.
        var best: VNRecognizedTextObservation?
        var bestLen = 0
        var bestScore = -1.0
        for o in obs {
            guard let s = o.topCandidates(1).first?.string.lowercased() else { continue }
            let hit = s.hasSuffix(needle) || s.contains(needle) || needle.hasSuffix(s.suffix(min(s.count, 8)))
            if hit {
                let score = Double(1 - o.boundingBox.minY)   // lower on screen wins
                if score > bestScore { bestScore = score; best = o; bestLen = s.count }
            }
        }
        guard let match = best else { return nil }
        // boundingBox is normalized (origin bottom-left of the image). The caret is at
        // the trailing-right edge, on that line.
        let box = match.boundingBox
        let f = cap.frame
        let quartzX = f.minX + box.maxX * f.width
        let quartzTopY = f.minY + (1 - box.maxY) * f.height        // top of the text box, Quartz top-left
        let h = max(12, box.height * f.height)
        let charWidth = bestLen > 0 ? (box.width * f.width) / CGFloat(bestLen) : 9
        // Quartz top-left → AppKit bottom-left flip with the main-thread-snapshotted
        // primary height (same math as axRectToAppKit, but NSScreen-free off the main thread).
        let appkitY = primaryMaxY - quartzTopY - h
        return (CGRect(x: quartzX, y: appkitY, width: 1, height: h), charWidth)
    }

    // Refresh the cached background off the hot path, throttled by time + app key.
    func refreshBackgroundIfNeeded() {
        let key = activeAppKey
        // Refresh less often while saving power (fewer AX/screenshot wakeups).
        let interval = powerSaving ? max(cfg.backgroundRefreshSeconds, 10.0) : cfg.backgroundRefreshSeconds
        let fresh = Date().timeIntervalSince(backgroundRefreshedAt) < interval && key == backgroundKey
        if fresh || backgroundRefreshing { return }
        backgroundRefreshing = true
        // Snapshot cfg flags + frontmost PID on main (cfg mutates on main; NSWorkspace
        // is main-affine).
        let wantWindow = cfg.windowContextEnabled
        let wantScreen = cfg.screenContextEnabled
        let wantClipboard = cfg.clipboardContextEnabled
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recentText = String(buffer.suffix(300))   // for clipboard relevance
        backgroundQueue.async {
            var parts: [String] = []
            // Prefer clean AX text. Only fall back to (noisier) OCR when AX gives us
            // little — typically Electron apps. This keeps OCR misreads out of the
            // prompt whenever a reliable source exists.
            var windowChars = 0
            if wantWindow {
                let w = self.windowText(limit: 1000)
                if w.count > 40 { parts.append(w); windowChars = w.count }
            }
            if wantScreen, windowChars < 120 {
                let o = self.screenOCR(limit: 600, frontPID: frontPID)
                if o.count > 40 { parts.append(o) }
            }
            if wantClipboard {
                let c = self.clipboardText(limit: 200, relevantTo: recentText)
                if !c.isEmpty { parts.append("Clipboard: " + c) }
            }
            let bg = parts.joined(separator: "\n")
            DispatchQueue.main.async {
                self.cachedBackground = bg
                self.backgroundRefreshedAt = Date()
                self.backgroundKey = key
                self.backgroundRefreshing = false
                log("background refreshed key=\(key) chars=\(bg.count)")
            }
        }
    }

    // Ambient topic capture: periodically OCR the focused window, distill its salient
    // topics, and store them. Throttled by the timer (every topic_capture_seconds) and
    // single-flighted, so it stays cheap.
    func startTopicTimer() {
        topicTimer?.invalidate(); topicTimer = nil
        guard cfg.topicMemoryEnabled else { return }
        let period = max(60, cfg.topicCaptureSeconds)
        topicTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in self?.captureTopic() }
        // One capture shortly after enabling/launch so it doesn't feel inert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.captureTopic() }
    }

    func captureTopic() {
        guard cfg.topicMemoryEnabled, !topicCapturing, cfg.enabled else { return }
        if IsSecureEventInputEnabled() || isAppDisabled() { return }     // never capture secrets / disabled apps
        // Topic memory is for content you read (sites, docs), not terminals — those are
        // noisy (code/logs) and sensitive, so always skip them regardless of the
        // terminal-completion setting.
        if TyperApp.terminalBundleIDs.contains(currentAppBundleAndName().bundle) { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        if powerSaving { return }                                        // skip the screenshot+OCR burst on battery saver
        topicCapturing = true
        let appKey = activeAppKey
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        backgroundQueue.async {
            defer { DispatchQueue.main.async { self.topicCapturing = false } }
            guard let cap = self.captureFocusedWindow(frontPID: frontPID, scale: 0.5), cap.image.width > 8 else { return }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.minimumTextHeight = 0.012
            guard (try? VNImageRequestHandler(cgImage: cap.image, options: [:]).perform([req])) != nil,
                  let obs = req.results else { return }
            let text = obs.compactMap { o -> String? in
                guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
                return c.string
            }.joined(separator: "\n")
            guard text.count >= 80 else { return }
            let (keys, note) = distillTopics(text: text, title: cap.title)
            guard !keys.isEmpty, !note.isEmpty else { return }
            let appName = appKey.split(separator: "|").last.map(String.init) ?? appKey
            self.topicMemory.record(TopicEntry(at: Date().timeIntervalSince1970, app: appName,
                                               title: cap.title, keys: keys, note: note))
            log("topic captured app=\(appName) keys=\(keys.count)")
        }
    }

    // Assemble the final prompt context. The immediate before-cursor text always
    // comes LAST so the base model continues it; style + background precede it to
    // bias tone and topic. Heavy background is only folded in when the field itself
    // is sparse (chat boxes), where it helps most and risks the least regression.
    func assembledContext(immediate: String) -> String {
        var blocks: [String] = []
        let appName = currentAppBundleAndName().name
        if !appName.isEmpty { blocks.append("Writing app: \(appName)") }
        // Put ambient context before style, and the user's live text last. The base
        // model continues the final line; the earlier labeled blocks are background it
        // may consider for topic/tone, NOT content to tailor the completion to. Framed
        // as on-screen reference (and kept shorter) so a short live line doesn't get
        // overwhelmed and steered off into whatever happens to be on screen.
        if immediate.count < cfg.maxImmediateForBackground, !cachedBackground.isEmpty {
            blocks.append("(On screen now — background only, may not be relevant)\n" + String(cachedBackground.suffix(500)))
        }
        // Resurface a recently-viewed topic ONLY when the user is now typing about it
        // (a distinctive entity/keyword from it appears in their recent text).
        if cfg.topicMemoryEnabled, let note = topicMemory.relevant(to: String(immediate.suffix(220))) {
            blocks.append("Earlier relevant topic: \(note)")
        }
        if cfg.styleMemoryEnabled {
            // Cache the ranked sample for a few seconds: relevance doesn't need
            // keystroke granularity, ranking the whole corpus per keystroke costs
            // main-thread time, and a sample that reshuffles per request changes the
            // middle of the prompt — invalidating the helper's KV prefix cache that
            // the stable context windows exist to preserve.
            let maxChars = immediate.count < cfg.maxImmediateForBackground ? 360 : 160
            if Date().timeIntervalSince(styleSampleAt) > 5 || styleSampleChars != maxChars {
                cachedStyleSample = styleMemory.sample(maxChars: maxChars, relevantTo: immediate, category: appCategory())
                styleSampleAt = Date()
                styleSampleChars = maxChars
            }
            let s = cachedStyleSample
            if s.split(separator: " ").count >= 4 { blocks.append("Examples of my recent writing style:\n" + s) }
        }
        blocks.append(immediate)
        return blocks.count == 1 ? immediate : blocks.joined(separator: "\n\n")
    }
}
