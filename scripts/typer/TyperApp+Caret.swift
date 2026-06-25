import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Wave 1A caret core. The full fallback ladder (B.1), host-font reads (B.2), TextMirror
// (B.3), scroll invalidation (B.4), Google Docs (B.5), centralized coordinate conversion
// (B.6). All AX reads go through AXSafe (50 ms messaging timeout). Per-app
// verticalAlignmentOffset / fontSizeAdjustmentFactor from AppOverrides (W0) are applied to
// the chosen rect.

// The ladder step that produced a caret rect. The spec names this `CaretPath`, but a
// 2-case `CaretPath` (marker/bounds) already lives in TyperApp.swift (W1C-owned) for the
// inner marker-vs-bounds probe memo; to avoid editing another wave's file we expose the
// full 6-step ladder under this name. See the return summary's deviation note.
enum CaretLadderPath: Equatable { case marker, bounds, mirror, ocr, click, frame }

// All mutable caret-subsystem state lives here (a stored-property holder) so it can be
// owned entirely by Wave 1A without adding stored properties to the W1C-owned TyperApp
// (extensions cannot declare stored properties).
final class CaretState {
    static let shared = CaretState()
    private init() {}

    // Which ladder step last succeeded per bundle id — so we try the winning path first
    // and don't pay failing synchronous IPC round-trips probing dead ones every re-anchor.
    var ladderPathByBundle: [String: CaretLadderPath] = [:]
    // Host font cached per bundle, keyed by font descriptor string (Cotypist's
    // LineHeightCache analogue). Lets ghost width/height use the real font without an AX
    // read on every keystroke.
    var fontByBundle: [String: NSFont] = [:]
    var colorByBundle: [String: NSColor] = [:]
    // The TextMirror overlay (lazily created on first mirror use).
    var mirrorWindow: TextMirrorWindow?
    var mirrorActive = false
    // ScrollWheelMonitor (lazily started once).
    var scrollMonitor: ScrollMonitor?
    // Pids we've already enabled AXEnhancedUserInterface on — set ONCE per app (review H2:
    // re-asserting EUI on every re-anchor forces Office to rebuild its AX tree = main-thread stall).
    var enhancedUIPids: Set<pid_t> = []
    // Bundles for which the Google Docs "enable accessibility" dialog was already shown.
    var docsPrompted: Set<String> = []
}

extension TyperApp {
    var caretState: CaretState { CaretState.shared }

    // Best-effort caret point for the overlay. AX is the fast, exact path; if it
    // fails we use a cached screenshot caret extrapolated horizontally by how much
    // has been typed since, and kick off a throttled refresh in the background.
    func currentCaretPoint(allowBackwardFrom optimistic: NSPoint? = nil) -> NSPoint {
        // Install the scroll monitor once (idempotent). Done lazily here rather than at
        // launch because applicationDidFinishLaunching is owned by another wave; the first
        // caret placement is a safe, main-thread, one-time hook.
        startScrollMonitor()
        // Stash the host font/color so the overlay renders the ghost in the field's real
        // typography (B.2). Cheap (cached per bundle); set once per placement.
        let (hostFont, hostColor) = currentHostFont()
        overlay.pendingHostFont = hostFont
        overlay.pendingHostColor = hostColor
        if var ax = caretPoint() {
            // During a fast type-through, the host app often updates its AX caret a
            // frame later than our event tap. If a delayed re-anchor reports the old
            // same-line x position, keep the optimistic forward-shifted point instead
            // of snapping the ghost back over the current word. Real cursor moves are
            // handled by mouse-down invalidation, and line wraps still win via y change.
            if let optimistic,
               abs(ax.y - optimistic.y) <= max(6, lastCaretHeight * 0.65),
               ax.x + 1 < optimistic.x {
                ax = optimistic
            }
            shotCaretPoint = nil          // AX is authoritative; drop stale screenshot cache
            lastCaretPoint = ax
            return ax
        }
        if cfg.screenshotCaretEnabled { refreshShotCaretIfNeeded() }
        if let p = shotCaretPoint, shotCaretApp == activeAppKey,
           Date().timeIntervalSince(shotCaretAt) < 6 {
            let typedSince = max(0, buffer.count - shotCaretBufferLen)
            let extrapolated = NSPoint(x: p.x + CGFloat(typedSince) * shotCaretCharWidth, y: p.y)
            lastCaretPoint = extrapolated
            lastCaretHeight = shotCaretHeight
            recordLadderPath(.ocr)
            return extrapolated
        }
        // Click-anchor caret: a left-click placed the caret where the user clicked.
        // Extrapolate horizontally by the measured width of what they've typed since,
        // reusing the per-app width calibration. Cheap (no capture/OCR) and the primary
        // placement path for Electron/web fields that expose no AX caret. Bounded: a
        // newline or a long burst since the click means wraps we can't track on one
        // line, so we stop trusting the anchor and fall through.
        if cfg.clickCaretEnabled, let anchor = clickCaretPoint, clickCaretApp == activeAppKey,
           Date().timeIntervalSince(clickCaretAt) < 45 {
            let typedSince = String(buffer.suffix(max(0, buffer.count - clickCaretBufferLen)))
            if typedSince.count <= 200, !typedSince.contains(where: { $0 == "\n" || $0 == "\r" }) {
                let advance = typedSince.isEmpty ? 0 : ghostWidth(typedSince) * widthScale()
                // anchor.y is the click's vertical center; drop half a line height (using
                // the now-current field height) to the line bottom the overlay renders from.
                var est = NSPoint(x: anchor.x + advance, y: anchor.y - lastCaretHeight / 2)
                if let optimistic, abs(est.y - optimistic.y) <= max(6, lastCaretHeight * 0.65),
                   est.x + 1 < optimistic.x { est = optimistic }
                lastCaretPoint = est
                recordLadderPath(.click)
                return est
            }
        }
        recordLadderPath(.frame)
        return lastCaretPoint ?? focusedElementPoint() ?? NSPoint(x: 400, y: 400)
    }

    // Record where a left-click landed as a caret seed. `cgPoint` is CGEvent.location:
    // global, top-left origin, the same space AX uses — flip to AppKit bottom-left via
    // CoordinateUtil (primary-screen height). We store the click's vertical CENTER and
    // apply the half-line-height drop to the line bottom at consume time, not here.
    func recordClickCaret(at cgPoint: CGPoint) {
        clickCaretPoint = CoordinateUtil.axPointToAppKit(cgPoint)
        clickCaretAt = Date()
        clickCaretPending = true
    }

    // The region (global Quartz, top-left) the screenshot caret locator should capture:
    // the focused element's bounds, narrowed to a few-line band around the best caret y
    // anchor we have. Returning a thin band instead of the whole window is what makes
    // the screenshot path cheap enough to run while typing. Main-thread only (reads AX).
    func caretCaptureClip() -> CGRect? {
        guard let rect = focusedElementQuartzRect() else { return nil }
        let lineH = max(lastCaretHeight, shotCaretHeight, 16)
        // If the field is short (single/few-line input) the whole element IS the band.
        guard rect.height > lineH * 8, let anchorAppKitY = lastCaretPoint?.y ?? clickCaretPoint?.y else { return rect }
        let primaryMaxY = CoordinateUtil.primaryMaxY()
        // anchor is the line's bottom in AppKit (bottom-left); convert to the line's top
        // in Quartz (top-left), then pad a few lines each way.
        let quartzLineTop = primaryMaxY - anchorAppKitY - lineH
        let pad = lineH * 4
        let top = max(rect.minY, quartzLineTop - pad)
        let bottom = min(rect.maxY, quartzLineTop + lineH + pad)
        guard bottom - top >= 12 else { return rect }
        return CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
    }

    func refreshShotCaretIfNeeded() {
        // Uses Screen Recording (same permission as OCR context) but is independent
        // of the OCR-context toggle — caret placement should work even with it off.
        if shotCaretComputing { return }
        // Recompute when stale or after meaningful typing since the last fix. Each
        // recompute is a screenshot + OCR, so throttle hard: extrapolate horizontally
        // between captures and only re-capture after a real pause or large drift.
        let stale = Date().timeIntervalSince(shotCaretAt) > 4.0 || shotCaretApp != activeAppKey
        let drift = abs(buffer.count - shotCaretBufferLen) > 24
        guard stale || drift else { return }
        shotCaretComputing = true
        let appKey = activeAppKey
        let bufLen = buffer.count
        // Snapshot everything off `self` ON THE MAIN THREAD; the background closure
        // must not touch self.buffer / AX / NSWorkspace (off-main = crash/UB).
        let needle = String(String(buffer.suffix(40)).trimmingCharacters(in: .whitespacesAndNewlines).suffix(18)).lowercased()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clip = caretCaptureClip()
        // NSScreen is main-affine; snapshot the primary-display height here so the
        // background OCR closure can do the Quartz→AppKit flip without touching NSScreen.
        let primaryMaxY = CoordinateUtil.primaryMaxY()
        backgroundQueue.async {
            let res = self.screenshotCaretRect(needle: needle, frontPID: frontPID, clip: clip, primaryMaxY: primaryMaxY)
            DispatchQueue.main.async {
                self.shotCaretComputing = false
                guard appKey == self.activeAppKey, let res else { return }
                self.shotCaretPoint = NSPoint(x: res.rect.maxX + 2, y: res.rect.minY)
                self.shotCaretCharWidth = res.charWidth
                self.shotCaretHeight = res.rect.height
                self.shotCaretBufferLen = bufLen
                self.shotCaretAt = Date()
                self.shotCaretApp = appKey
                // Re-place the live suggestion now that we know where the caret is.
                if self.completion != nil { self.showCompletionRemainder() }
            }
        }
    }

    func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = axSystemWideElement()
        return axFocusedElement(of: system)
    }

    struct AXContext {
        var before: String
        var after: String
    }

    // Reads the text up to and after the caret from the focused element's AXValue
    // + selected range. Mirrors Cotypist's textUpToCursor / textAfterCursor split:
    // `before` drives the completion prompt; `after` lets us suppress mid-line
    // suggestions (don't autocomplete into the middle of existing text).
    func textAroundCursor(limit: Int) -> AXContext? {
        guard let element = focusedElement() else { return nil }
        guard let value = axString(element, kAXValueAttribute as String), !value.isEmpty else { return nil }
        // Guard the hot path: terminals and large editors expose enormous AXValues
        // (Ghostty reports ~400k chars). Copying that on every keystroke would jank
        // the event tap, so fall back to the keystroke buffer for oversized fields.
        guard value.utf16.count <= 20000 else {
            log("[\(activeAppKey)] AX value too large (\(value.count) chars); using key buffer")
            return nil
        }
        guard let rangeValue = axRead(element, kAXSelectedTextRangeAttribute as String) else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        let utf16 = value.utf16
        let cut = min(range.location, utf16.count)
        let caretIdx = String.Index(utf16Offset: cut, in: value)
        // stableTail, not suffix: a window that slides per keystroke makes the prompt
        // prefix differ on every request and defeats the helper's KV prefix cache.
        let before = stableTail(String(value[..<caretIdx]), max: limit)
        let after = String(String(value[caretIdx...]).prefix(limit))
        dlog("[\(activeAppKey)] AX text context valueChars=\(value.count) cursorUtf16=\(range.location) before=\(before.count) after=\(after.count)")
        return AXContext(before: before, after: after)
    }

    // True when the caret sits in the middle of a word/line of existing text, e.g.
    // editing "the qu|ick fox". Inline continuation there would be wrong, so we
    // suppress it — matching Cotypist's mid-line completion behavior.
    func isMidLine(after: String) -> Bool {
        // Suppress if ANY real text remains on the current line after the caret
        // (not just the immediately-adjacent char) — completing into "hello| world"
        // is as wrong as "the qu|ick". Trailing whitespace before a newline is fine.
        let restOfLine = after.prefix { $0 != "\n" && $0 != "\r" }
        return restOfLine.contains { !$0.isWhitespace }
    }

    // AX caret height is inconsistent — the same field yields a tight line-height on
    // one read and the whole field height on the next (when the precise BoundsForRange
    // branch fails). Since the real line height never grows within a focus session,
    // floor to the smallest seen so the ghost font never jumps comically large.
    func stabilizeCaretHeight(_ h: CGFloat) -> CGFloat {
        guard h > 0 else { return h }
        let f = min(h, caretHeightFloor ?? h)
        caretHeightFloor = f
        return f
    }

    // MARK: - Host font (B.2)

    // Read the focused element's REAL font + color for the caret char range, via the
    // AXAttributedStringForRange parameterized attribute. Cached per bundle keyed by font
    // descriptor so the hot path doesn't pay an AX read every keystroke. This is what
    // kills fast-typing drift: ghost width/height use the host font instead of
    // NSFont.systemFont, and the widthScale EMA converges to ~1.0.
    func focusedElementFont(_ el: AXUIElement, at loc: Int) -> (font: NSFont, color: NSColor?)? {
        var range = CFRange(location: max(0, loc), length: 1)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        if let attrRef = axReadParam(el, kAXAttributedStringForRangeParameterizedAttribute as String, axRange),
           let s = attrRef as? NSAttributedString, s.length > 0 {
            let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let c = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            if let f { return (f, c) }
        }
        return nil
    }

    // The current host font/color for the focused element, cached per bundle. Falls back
    // to a system font sized to the current caret line height when AX exposes none.
    func currentHostFont() -> (font: NSFont, color: NSColor) {
        let bundle = currentAppBundleAndName().bundle
        let scale = CGFloat(OverrideStore.shared.resolved(bundle: bundle).fontSizeAdjustmentFactor ?? 1.0)
        if let el = focusedElement(),
           let loc = caretCharIndex(el),
           let read = focusedElementFont(el, at: loc) {
            let scaled = scale == 1.0 ? read.font
                : (NSFont(descriptor: read.font.fontDescriptor, size: read.font.pointSize * scale) ?? read.font)
            caretState.fontByBundle[bundle] = scaled
            if let c = read.color { caretState.colorByBundle[bundle] = c }
            return (scaled, read.color ?? NSColor.labelColor)
        }
        if let cached = caretState.fontByBundle[bundle] {
            return (cached, caretState.colorByBundle[bundle] ?? NSColor.labelColor)
        }
        let fs = min(max(lastCaretHeight * 0.62, 11), 30) * scale
        return (NSFont.systemFont(ofSize: fs), NSColor.labelColor)
    }

    // The caret character index in the focused element (for font/mirror reads).
    func caretCharIndex(_ el: AXUIElement) -> Int? {
        guard let rangeValue = axRead(el, kAXSelectedTextRangeAttribute as String) else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range.location
    }

    // MARK: - Coordinate conversion (B.6, centralized)

    func axRectToAppKit(_ rect: CGRect) -> CGRect { CoordinateUtil.axRectToAppKit(rect) }

    // MARK: - The fallback ladder (B.1)

    // Explicit, ordered, per-bundle-memoized caret placement. Steps:
    //   1 marker  AXTextMarker bounds (Chromium/WebKit/Electron)
    //   2 bounds  AXBoundsForRange ladder (native AppKit, AX terminals)
    //   3 mirror  TextMirror font-exact glyph rect (Docs/web canvas/Catalyst/no-inline)
    //   4 ocr     screenshot/OCR caret (GPU terminals, custom editors)
    //   5 click   click-anchor + host-font width extrapolation
    //   6 frame   focused-element frame center (last resort)
    // After a rect is chosen, the per-app verticalAlignmentOffset is applied.
    func caretRect(for el: AXUIElement, bundle: String) -> (rect: CGRect, path: CaretLadderPath)? {
        let ov = OverrideStore.shared.resolved(bundle: bundle, host: currentWebHost())
        // TextMirror fallback is TEMPORARILY DISABLED. Review M1/H3: the mirror window
        // double-renders the ghost and mis-places the caret (it feeds ~4000 chars into a
        // one-line window), and it was firing as an auto-ladder step for AX-hostile apps
        // (terminals/editors) — surfacing a stale mirror overlay at the screen corner.
        // Until the windowing is rewritten, dismiss any stale mirror and use the solid
        // inline → OCR → click → frame ladder for every app. (mirrorCaretRect / .mirror
        // remain in the source, currently unreachable, for the planned rewrite.)
        dismissMirrorIfActive()
        // Try the winning path first, else probe in ladder order.
        let preferred = caretState.ladderPathByBundle[bundle]
        let order: [CaretLadderPath] = orderedLadder(preferred: preferred)
        for step in order {
            switch step {
            case .marker:
                if let r = textMarkerCaretRect(element: el) {
                    recordLadderPath(.marker); caretPathByBundle[bundle] = .marker
                    return (applyVerticalOffset(r, ov), .marker)
                }
            case .bounds:
                if let r = boundsForSelectedRange(element: el) {
                    recordLadderPath(.bounds); caretPathByBundle[bundle] = .bounds
                    return (applyVerticalOffset(r, ov), .bounds)
                }
            case .mirror:
                if let r = mirrorCaretRect(el: el, bundle: bundle, overrides: ov) {
                    recordLadderPath(.mirror)
                    return (r, .mirror)   // mirror rect already includes vOffset
                }
            case .ocr, .click, .frame:
                // Handled by currentCaretPoint's cached screenshot/click/frame branches,
                // not re-probed here (they are not AX-rect producers).
                break
            }
        }
        return nil
    }

    private func orderedLadder(preferred: CaretLadderPath?) -> [CaretLadderPath] {
        let base: [CaretLadderPath] = [.marker, .bounds]   // .mirror disabled (review M1/H3)
        guard let preferred, base.contains(preferred) else { return base }
        return [preferred] + base.filter { $0 != preferred }
    }

    func recordLadderPath(_ p: CaretLadderPath) {
        let bundle = currentAppBundleAndName().bundle
        if caretState.ladderPathByBundle[bundle] != p {
            caretState.ladderPathByBundle[bundle] = p
            dlog("[\(activeAppKey)] caret path -> \(p)")
        }
    }

    // Apply the per-app vertical nudge (AppOverrides.verticalAlignmentOffset) to a chosen
    // AppKit rect. Positive offset moves the ghost up (matches Cotypist's overlay nudge).
    private func applyVerticalOffset(_ rect: CGRect, _ ov: AppOverrides) -> CGRect {
        guard let off = ov.verticalAlignmentOffset, off != 0 else { return rect }
        return rect.offsetBy(dx: 0, dy: CGFloat(off))
    }

    // MARK: - caretPoint (now ladder-driven)

    func caretPoint() -> NSPoint? {
        guard let element = focusedElement() else { return nil }
        let bundle = currentAppBundleAndName().bundle

        // Apply AXEnhancedUserInterface for apps that need it to expose AX text (D.5).
        applyEnhancedUserInterfaceIfNeeded(bundle: bundle)

        guard let (rect, path) = caretRect(for: element, bundle: bundle) else {
            maybePromptGoogleDocs(element: element, bundle: bundle)
            return nil
        }
        if path != .mirror { dismissMirrorIfActive() }
        // Derive caret height from the host font when available (B.2): use
        // ascender-descender+leading instead of the monotone stabilize floor, which never
        // recovers from a too-small first read. Fall back to the floor when no font.
        if let loc = caretCharIndex(element), let read = focusedElementFont(element, at: loc) {
            let f = read.font
            let h = ceil(f.ascender - f.descender + f.leading)
            lastCaretHeight = h > 4 ? h : stabilizeCaretHeight(rect.height)
        } else {
            lastCaretHeight = stabilizeCaretHeight(rect.height)
        }
        // The mirror path draws in its own window; return its in-screen caret right edge.
        let point = NSPoint(x: rect.maxX + 2, y: rect.minY)
        dlog("caret point=\(point) h=\(rect.height) path=\(path) from rect=\(rect)")
        return point
    }

    // MARK: - TextMirror (B.3)

    // Build (or update) the mirror window for the focused element and return the caret
    // rect in screen (AppKit) coordinates. Needs only (text, caret index, font) — drives
    // the mirror from textAroundCursor + the host font, anchors to the field's AX frame.
    func mirrorCaretRect(el: AXUIElement, bundle: String, overrides ov: AppOverrides) -> CGRect? {
        guard let fieldQuartz = focusedElementQuartzRect() else { return nil }
        guard let ctx = textAroundCursor(limit: 2000) else { return nil }
        let (font, color) = currentHostFont()
        let win = caretState.mirrorWindow ?? {
            let w = TextMirrorWindow(); caretState.mirrorWindow = w; return w
        }()
        let fieldAppKit = CoordinateUtil.axRectToAppKit(fieldQuartz)
        let caretIdx = (ctx.before as NSString).length
        let text = ctx.before + ctx.after
        let suggestion = completion?.remainder ?? ""
        let vOffset = CGFloat(ov.verticalAlignmentOffset ?? 0)
        win.present(fieldRect: fieldAppKit, text: text, caret: caretIdx,
                    suggestion: suggestion, font: font, color: color, vOffset: vOffset)
        caretState.mirrorActive = true
        // Caret rect inside the mirror, mapped into screen coords. The mirror view is
        // flipped (top-left); convert to AppKit (bottom-left) within the window frame.
        let inView = win.mirrorView.caretRectInMirror()
        let viewFrameInWindow = win.mirrorView.frame
        let screenY = win.frame.minY + viewFrameInWindow.minY + (viewFrameInWindow.height - inView.maxY)
        let screenX = win.frame.minX + viewFrameInWindow.minX + inView.minX
        win.markBannerSeen()
        return CGRect(x: screenX, y: screenY, width: inView.width, height: inView.height)
    }

    // Hide the mirror when placement reverts to an inline path or focus is lost.
    func dismissMirrorIfActive() {
        guard caretState.mirrorActive else { return }
        caretState.mirrorWindow?.dismiss()
        caretState.mirrorActive = false
    }

    // MARK: - Google Docs (B.5)

    // Detect docs.google.com with an empty AX text tree and prompt the user (once) to turn
    // on Docs' own screen-reader support — the only way Docs exposes a DOM/AX text tree.
    // Once enabled, Docs is routed through TextMirror via the in-code domain override.
    func maybePromptGoogleDocs(element: AXUIElement, bundle: String) {
        guard let host = currentWebHost(), host.hasSuffix("docs.google.com") else { return }
        // Only prompt if the field really has no text tree (a11y not yet enabled).
        if let v = axString(element, kAXValueAttribute as String), !v.isEmpty { return }
        guard !caretState.docsPrompted.contains(bundle) else { return }
        caretState.docsPrompted.insert(bundle)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enable Google Docs accessibility"
            alert.informativeText = "Google Docs doesn't expose its text to typer until you turn on screen-reader support. In Docs: Tools → Accessibility… → enable \u{201C}Turn on screen reader support\u{201D} (\u{2318}\u{2325}Z). typer will then show suggestions in a mirror preview."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    // The web host of the focused window (docs.google.com etc.), read over AX. Used for
    // the Google Docs branch (B.5) and domain-scoped AppOverrides resolution. Tries the
    // window's AXURL first, then falls back to parsing a URL out of the window title.
    func currentWebHost() -> String? {
        guard let element = focusedElement() else { return nil }
        // Walk to the containing window.
        var windowEl: AXUIElement? = axRead(element, kAXWindowAttribute as String).map { $0 as! AXUIElement }
        if let w = windowEl { windowEl = axBound(w) }
        if let w = windowEl {
            if let urlVal = axRead(w, "AXURL") {
                if let url = urlVal as? URL, let h = url.host { return h.lowercased() }
                if let s = urlVal as? String, let url = URL(string: s), let h = url.host { return h.lowercased() }
            }
            if let title = axString(w, kAXTitleAttribute as String), let h = hostFromText(title) {
                return h
            }
        }
        return nil
    }

    private func hostFromText(_ text: String) -> String? {
        // Look for the first http(s) URL in the title; many browsers append the URL.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            if let m = detector.firstMatch(in: text, options: [], range: range),
               let url = m.url, let h = url.host { return h.lowercased() }
        }
        return nil
    }

    // MARK: - AXEnhancedUserInterface (D.5)

    private func applyEnhancedUserInterfaceIfNeeded(bundle: String) {
        guard OverrideStore.shared.resolved(bundle: bundle).needsEnhancedUserInterface == true else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        // Set ONCE per app launch (review H2). Re-issuing the SET on every re-anchor makes
        // Office rebuild its AX tree synchronously and stalls the main thread.
        guard !caretState.enhancedUIPids.contains(pid) else { return }
        caretState.enhancedUIPids.insert(pid)
        let appEl = axAppElement(pid)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - ScrollWheelMonitor (B.4)

    // Install the scroll monitor once: scrolling a long doc leaves the AX/shot/click caret
    // anchors stale, so invalidate them and re-anchor, mirroring mouse-down invalidation.
    func startScrollMonitor() {
        guard caretState.scrollMonitor == nil else { return }
        let mon = ScrollMonitor { [weak self] in self?.invalidateCaretOnScroll() }
        caretState.scrollMonitor = mon
        mon.start()
    }

    private func invalidateCaretOnScroll() {
        // Drop the stale geometry caches; the click anchor and OCR caret both move with the
        // viewport on a scroll, and the AX rect is one frame behind.
        shotCaretPoint = nil
        clickCaretPoint = nil
        clickCaretApp = ""
        lastCaretPoint = caretPoint()   // re-anchor immediately from a fresh AX read
        if completion != nil { showCompletionRemainder(reanchor: true) }
        dlog("[\(activeAppKey)] scroll re-anchor")
    }

    // MARK: - Caret rect via AX text marker / bounds

    // Caret rect via the WebKit/Chromium AXTextMarker attributes. These are private
    // string-named AX attributes (not in the public constants) but are read the same
    // way; the marker-range value is opaque and just passed straight through.
    func textMarkerCaretRect(element: AXUIElement) -> CGRect? {
        guard let markerRange = axRead(element, "AXSelectedTextMarkerRange") else { return nil }
        guard let boundsRef = axReadParam(element, "AXBoundsForTextMarkerRange", markerRange) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        // A collapsed caret comes back zero-width, so validate directly here rather
        // than via isPlausibleCaretRect (which assumes a non-zero width).
        let r = axRectToAppKit(rect)
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.height >= 4, r.height <= 200, r.width <= 2000 else { return nil }
        if r.origin.x == 0 && r.origin.y == 0 { return nil }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(r.insetBy(dx: -2, dy: -2)) }) else { return nil }
        dlog("[\(activeAppKey)] caret via text marker rect=\(r)")
        return r
    }

    func focusedElementPoint() -> NSPoint? {
        guard let element = focusedElement() else { return nil }
        guard let posValue = axRead(element, kAXPositionAttribute as String),
              let sizeValue = axRead(element, kAXSizeAttribute as String) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let rect = axRectToAppKit(CGRect(origin: point, size: size))
        // Single-line inputs (search bars, chat boxes): vertically center on the
        // field's one text line instead of guessing 24px down from the top, which
        // landed the ghost below short fields. Tall views keep the top-area guess.
        let fallback = rect.height <= 60
            ? NSPoint(x: rect.minX + 12, y: rect.midY - lastCaretHeight / 2)
            : NSPoint(x: rect.minX + 12, y: rect.maxY - 24)
        dlog("fallback focused element point=\(fallback) ax=\(point) size=\(size) converted=\(rect)")
        return fallback
    }

    // A caret rect coming back from AX is only trustworthy if it is finite,
    // on-screen, and has a plausible line height. Many apps return (0,0,0,0),
    // the whole text view, or NaN for a zero-length caret range — reject those.
    func isPlausibleCaretRect(_ r: CGRect) -> Bool {
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite else { return false }
        if r.height < 4 || r.height > 200 { return false }
        if r.width > 2000 { return false } // whole-text-view bounds, not a caret
        if r.origin.x == 0 && r.origin.y == 0 { return false } // classic bogus origin
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(r.insetBy(dx: -2, dy: -2)) }
        return onScreen
    }

    func boundsForSelectedRange(element: AXUIElement) -> CGRect? {
        guard let rangeValue = axRead(element, kAXSelectedTextRangeAttribute as String) else {
            dlog("AX selected range unavailable"); return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }

        // Returns the AX rect (top-left origin) for a character range, or nil.
        func axRect(for input: CFRange) -> CGRect? {
            var r = input
            guard let rangeAx = AXValueCreate(.cfRange, &r) else { return nil }
            guard let boundsValue = axReadParam(element, kAXBoundsForRangeParameterizedAttribute as String, rangeAx) else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
            return rect
        }
        // Converts to AppKit coords and accepts only if plausible.
        func caret(from input: CFRange, anchor: (CGRect) -> CGRect) -> CGRect? {
            guard let r0 = axRect(for: input) else { return nil }
            let r = axRectToAppKit(r0)
            let c = anchor(r)
            return isPlausibleCaretRect(c) ? c : nil
        }

        // 1. Active selection: highlight the selected glyphs directly.
        if range.length > 0, let r = caret(from: range, anchor: { $0 }) {
            dlog("AX selected rect loc=\(range.location) len=\(range.length) rect=\(r)")
            return r
        }
        // 2. Zero-length caret: some apps return a valid thin caret rect here.
        if let r = caret(from: range, anchor: { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }) {
            dlog("AX caret direct loc=\(range.location) rect=\(r)")
            return r
        }
        // 3. cursorRectIsFromPreviousCharacter: anchor to the end of the prior glyph.
        if range.location > 0,
           let r = caret(from: CFRange(location: range.location - 1, length: 1),
                         anchor: { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }) {
            dlog("AX caret inferred from prev loc=\(range.location) rect=\(r)")
            return r
        }
        // 4. Anchor to the start of the next glyph.
        if let r = caret(from: CFRange(location: range.location, length: 1),
                         anchor: { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }) {
            dlog("AX caret inferred from next loc=\(range.location) rect=\(r)")
            return r
        }
        // 5. beginningOfParagraphRect: walk back to the line/paragraph start so we
        //    at least land on the correct text line when the exact glyph fails.
        // Cap the back-scan: each step is a synchronous AXBoundsForRange IPC round-trip,
        // so a deep scan can stall the main thread. 40 glyphs is plenty to recover the
        // current line; beyond that we fall back rather than block.
        var lineStart = range.location
        while lineStart > 0 && lineStart > range.location - 40 {
            if let r = caret(from: CFRange(location: lineStart - 1, length: 1),
                             anchor: { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }) {
                dlog("AX caret from paragraph scan loc=\(lineStart) rect=\(r)")
                return r
            }
            lineStart -= 1
        }
        dlog("AX bounds unavailable for range loc=\(range.location) len=\(range.length)")
        return nil
    }
}
