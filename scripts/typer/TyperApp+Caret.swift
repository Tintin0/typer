import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // Best-effort caret point for the overlay. AX is the fast, exact path; if it
    // fails we use a cached screenshot caret extrapolated horizontally by how much
    // has been typed since, and kick off a throttled refresh in the background.
    func currentCaretPoint(allowBackwardFrom optimistic: NSPoint? = nil) -> NSPoint {
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
            return extrapolated
        }
        return lastCaretPoint ?? focusedElementPoint() ?? NSPoint(x: 400, y: 400)
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
        // must not touch self.buffer (concurrent String mutation = crash).
        let needle = String(String(buffer.suffix(40)).trimmingCharacters(in: .whitespacesAndNewlines).suffix(18)).lowercased()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        backgroundQueue.async {
            let res = self.screenshotCaretRect(needle: needle, frontPID: frontPID)
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
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
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
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, !value.isEmpty else { return nil }
        // Guard the hot path: terminals and large editors expose enormous AXValues
        // (Ghostty reports ~400k chars). Copying that on every keystroke would jank
        // the event tap, so fall back to the keystroke buffer for oversized fields.
        guard value.utf16.count <= 20000 else {
            log("[\(activeAppKey)] AX value too large (\(value.count) chars); using key buffer")
            return nil
        }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
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

    func caretPoint() -> NSPoint? {
        guard let element = focusedElement() else { return nil }
        // Chromium/Electron and WebKit (Discord, Slack, VS Code, Chrome, Safari)
        // expose the most reliable live caret via AXTextMarker. Prefer that path;
        // some of those apps also answer AXBoundsForRange, but one frame stale or
        // anchored to the previous glyph, which puts the ghost over the current word.
        // Native AppKit text views usually use AXBoundsForRange, so keep it as the
        // fallback. Which path an app answers is toolkit-level and never changes, so
        // remember it per bundle: caret reads happen on every re-anchor, and probing
        // the wrong API first costs two failing synchronous IPC round-trips each time.
        let bundle = currentAppBundleAndName().bundle
        var rect: CGRect?
        var path: CaretPath?
        if caretPathByBundle[bundle] == .bounds {
            if let r = boundsForSelectedRange(element: element) { rect = r; path = .bounds }
            else if let r = textMarkerCaretRect(element: element) { rect = r; path = .marker }
        } else {
            if let r = textMarkerCaretRect(element: element) { rect = r; path = .marker }
            else if let r = boundsForSelectedRange(element: element) { rect = r; path = .bounds }
        }
        guard let rect else { return nil }
        if let path { caretPathByBundle[bundle] = path }
        // rect is already in AppKit (bottom-left) coordinates. Return the caret's
        // right edge + bottom; the line height lets the overlay render inline.
        lastCaretHeight = stabilizeCaretHeight(rect.height)
        let point = NSPoint(x: rect.maxX + 2, y: rect.minY)
        dlog("caret point=\(point) h=\(rect.height) from rect=\(rect)")
        return point
    }

    // Caret rect via the WebKit/Chromium AXTextMarker attributes. These are private
    // string-named AX attributes (not in the public constants) but are read the same
    // way; the marker-range value is opaque and just passed straight through.
    func textMarkerCaretRect(element: AXUIElement) -> CGRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef) == .success,
              let boundsRef else { return nil }
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
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return nil }
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

    func axRectToAppKit(_ rect: CGRect) -> CGRect {
        // AX APIs report global coordinates with a top-left origin anchored at the
        // top-left of the PRIMARY display (the menu-bar / zero-origin screen) — the
        // same space as CGEvent / CGDisplayBounds. AppKit (NSPanel.setFrame,
        // NSScreen.frame) uses a bottom-left origin anchored at the bottom-left of
        // that same primary screen. The flip therefore must use the primary
        // screen's height, NOT the height of whatever screen the rect lands on.
        // Using the local screen's maxY breaks on multi-monitor setups.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryMaxY = primary?.frame.maxY ?? rect.maxY
        return CGRect(x: rect.origin.x,
                      y: primaryMaxY - rect.origin.y - rect.height,
                      width: rect.width,
                      height: rect.height)
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
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { dlog("AX selected range unavailable"); return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }

        // Returns the AX rect (top-left origin) for a character range, or nil.
        func axRect(for input: CFRange) -> CGRect? {
            var r = input
            guard let rangeAx = AXValueCreate(.cfRange, &r) else { return nil }
            var boundsRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeAx, &boundsRef) == .success,
                  let boundsValue = boundsRef else { return nil }
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
