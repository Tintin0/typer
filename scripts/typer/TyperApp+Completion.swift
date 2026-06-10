import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // Rendered width of `s` at the current ghost font (used to advance the overlay
    // as the user types through a suggestion without re-reading the caret).
    func ghostWidth(_ s: String) -> CGFloat {
        let fs = min(max(lastCaretHeight * 0.62, 11), 30)
        let measured = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fs)]).width
        // Bias slightly forward. The host app may use a wider font than our ghost
        // renderer; being a few pixels ahead is far less distracting than sitting on
        // top of the word the user is actively typing, and the delayed AX re-anchor
        // corrects any overshoot.
        return measured + max(1, CGFloat(s.count) * 0.8)
    }

    // reanchor=true re-reads the caret from AX (fresh suggestion / new line);
    // reanchor=false reuses the cached point (already shifted by typed width) to
    // avoid per-keystroke AX jitter. trustAX=true drops the no-backward-snap guard
    // so a late re-anchor can correct accumulated forward overshoot.
    func showCompletionRemainder(reanchor: Bool = true, animate: Bool = false, trustAX: Bool = false) {
        guard let comp = completion, !comp.done else { overlay.orderOut(nil); return }
        let guardPoint = (comp.consumed > 0 && !trustAX) ? lastCaretPoint : nil
        let point = reanchor ? currentCaretPoint(allowBackwardFrom: guardPoint) : (lastCaretPoint ?? currentCaretPoint())
        overlay.showCompletion(comp.remainder, at: point, lineHeight: lastCaretHeight, animate: animate)
    }

    // Our tap callback runs BEFORE the host app applies the keystroke, so reading the
    // AX caret right after typing/inserting gives a stale (one-step-behind) position —
    // that's the ghost overlapping what you just typed. Move immediately by measured
    // width, then re-anchor to the real caret a beat later once the app has caught up.
    // Coalesced, so fast typing never triggers a synchronous AX read.
    func scheduleReanchor() {
        reanchorWork?.cancel()
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.showCompletionRemainder(reanchor: true)
        }
        reanchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
        // The quick re-anchor above keeps the no-backward-snap guard (the host app's
        // AX caret may still be a frame behind), but ghostWidth deliberately overshoots,
        // so repeated Tab accepts accumulate rightward drift the guard then refuses to
        // correct. Once the app has definitely caught up, snap to the authoritative AX
        // caret — backwards included. Cancelled and re-armed on every keystroke, so it
        // only fires after a real pause.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.showCompletionRemainder(reanchor: true, trustAX: true)
        }
        settleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: settle)
    }

    // Tab: realize the next word of the prediction (we insert it; the user did not
    // type it) and keep the remainder showing.
    func acceptCompletionWord() -> Bool {
        guard var comp = completion, !comp.done else { return false }
        let end = comp.nextWordEnd()
        let piece = String(comp.chars[comp.consumed..<end])
        lastUserTypedAt = Date()
        insert(piece)
        appendToBuffer(piece)
        comp.consumed = end
        stats.accepted += 1; recordCompleted(piece); statsTouched()
        if comp.done {
            // Arm the grace window BEFORE completion=nil so refreshAcceptTap (its
            // didSet) never bounces the tap off and back on. A rapid next Tab is then
            // swallowed instead of tabbing focus away while the next chunk arrives.
            armAcceptGrace()
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate(quick: true) }
        } else {
            completion = comp
            // Move immediately by the inserted word's width (the app hasn't applied
            // the insertion yet), then re-anchor precisely once it has.
            if let p = lastCaretPoint { lastCaretPoint = NSPoint(x: p.x + ghostWidth(piece), y: p.y) }
            showCompletionRemainder(reanchor: false)
            scheduleReanchor()
            maybePrefetch()
        }
        return true
    }

    // Backtick: accept the whole remaining prediction at once.
    func acceptCompletionAll() -> Bool {
        guard let comp = completion, !comp.done else { return false }
        let piece = comp.remainder
        lastUserTypedAt = Date()
        insert(piece)
        appendToBuffer(piece)
        stats.accepted += 1; recordCompleted(piece); statsTouched()
        armAcceptGrace()
        completion = nil
        overlay.orderOut(nil)
        scheduleGenerate(quick: true)
        return true
    }

    // As the user nears the end of the current prediction, generate the NEXT chunk
    // in the background (as if they had typed through the rest) so it can appear
    // with zero perceived latency on exhaustion.
    func maybePrefetch() {
        // Prefetch roughly doubles inference; skip it entirely while saving power.
        guard cfg.prefetchEnabled, !powerSaving else { return }
        guard let comp = completion, !comp.done else { return }
        guard comp.chars.count - comp.consumed <= 12, !prefetchInFlight, !requestInFlight else { return }
        let predicted = stableTail(buffer + comp.remainder, max: 500)
        if predicted == prefetchKey, prefetched != nil { return }
        prefetchInFlight = true
        let promptContext = assembledContext(immediate: predicted)
        let appKey = activeAppKey
        let maxWords = cfg.maxCompletionWords
        backgroundQueue.async {
            let sug = (try? self.client.request(task: "complete", context: promptContext, maxWords: maxWords, lowPriority: true)) ?? nil
            DispatchQueue.main.async {
                self.prefetchInFlight = false
                guard appKey == self.activeAppKey, let t = sug?.text, !t.isEmpty else { return }
                self.prefetched = ActiveCompletion(chars: Array(t))
                self.prefetchKey = predicted
                log("prefetched chars=\(t.count)")
            }
        }
    }

    // If a prefetched chunk matches the current buffer state, show it instantly.
    func promotePrefetch() -> Bool {
        guard let pf = prefetched, prefetchKey == stableTail(buffer, max: 500) else { return false }
        completion = pf
        prefetched = nil
        prefetchKey = ""
        stats.shown += 1; statsTouched()   // a promoted prefetch is a shown suggestion
        showCompletionRemainder(animate: true)
        log("promoted prefetch")
        return true
    }

    func scheduleGenerate(quick: Bool = false) {
        debounce?.invalidate()
        var ms = powerSaving ? max(cfg.debounceMs, cfg.batteryDebounceMs) : cfg.debounceMs
        // An explicit accept that exhausted the suggestion is a direct request for
        // more. The debounce exists to coalesce keystrokes — there are none — so wait
        // only long enough for the host app to apply our insertion (the AX context
        // read must include it), not the full typing debounce.
        if quick { ms = min(ms, 60) }
        debounce = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000.0, repeats: false) { [weak self] _ in
            self?.generate()
        }
    }

    func generate() {
        syncActiveApp()
        if isAppDisabled() { clearSuggestion(); return }    // per-app / terminal disable
        // Inline completion is the only LLM-backed feature (typo correction is local,
        // via NSSpellChecker). If it's off, never touch the model helper.
        guard cfg.enabled, cfg.completionEnabled else { clearSuggestion(); return }
        // Only user text input should initiate completions. A click/focus change can
        // refresh context, but it must not create a suggestion; also ignore orphaned
        // timers that fire long after the typing burst that scheduled them.
        guard Date().timeIntervalSince(lastUserTypedAt) < 10.0 else { return }
        let serial = generationSerial
        // Single-flight: only one request may be in the helper at a time. Firing one
        // per keystroke (with ~400ms latency) backlogs the helper and every result
        // comes back stale — the cause of "nothing ever shows". If a request is in
        // flight we just remember to re-run with the latest context when it returns.
        if requestInFlight { rerequestNeeded = true; return }

        // Both context sources go through stableTail (not a sliding suffix) so the
        // prompt prefix stays byte-identical across keystrokes and the helper's KV
        // prefix cache actually hits. textAroundCursor applies it internally.
        let axCtx = textAroundCursor(limit: 500)
        let axContextRaw = axCtx?.before
        let keyContext = stableTail(buffer, max: 500)
        let axContext = (axContextRaw?.count ?? 0) >= max(cfg.minContextChars, min(20, keyContext.count / 2)) ? axContextRaw : nil
        let contextSource = axContext == nil ? "key-buffer" : "AXValue"
        let context = axContext ?? keyContext
        if axContext != nil, let after = axCtx?.after, isMidLine(after: after) {
            log("[\(activeAppKey)] generate skipped mid-line"); clearSuggestion(); return
        }
        // Remember the text right after the caret so we can drop completions that
        // just repeat it (e.g. at end of a line that already has following text).
        lastTrailing = (axContext != nil ? (axCtx?.after ?? "") : "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count >= cfg.minContextChars else { log("[\(activeAppKey)] generate skipped context=\(context.count) source=\(contextSource)"); return }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { log("[\(activeAppKey)] generate skipped question"); clearSuggestion(); return }
        refreshBackgroundIfNeeded()

        requestInFlight = true
        let appKey = activeAppKey
        let reqBuffer = buffer            // buffer snapshot for the staleness check
        let promptContext = assembledContext(immediate: context)
        let maxWords = cfg.maxCompletionWords
        dlog("[\(activeAppKey)] generate source=\(contextSource) chars=\(context.count) promptChars=\(promptContext.count) bg=\(cachedBackground.count) suffix=\(String(context.suffix(50)).replacingOccurrences(of: "\n", with: "\\n"))")
        // Anchor (an AX caret read) only on the FIRST painted partial; the user hasn't
        // typed since the request (guard below), so the caret can't have moved while
        // the rest of the tokens stream in — reuse the cached point instead of reading
        // AX per token.
        var firstPartial = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Live preview: paint partial completions as they stream in, but only
            // while the user hasn't typed since the request (else it's the final
            // line's job to reconcile via presentCompletion).
            let onPartial: (String) -> Void = { partial in
                DispatchQueue.main.async {
                    guard appKey == self.activeAppKey, self.generationSerial == serial,
                          self.buffer == reqBuffer, !partial.isEmpty else { return }
                    self.completion = ActiveCompletion(chars: Array(partial))
                    self.showCompletionRemainder(reanchor: firstPartial, animate: firstPartial)
                    firstPartial = false
                }
            }
            let sug = try? self.client.request(task: "complete", context: promptContext, maxWords: maxWords, onPartial: onPartial)
            DispatchQueue.main.async {
                self.requestInFlight = false
                let again = self.rerequestNeeded
                self.rerequestNeeded = false
                if appKey == self.activeAppKey, self.generationSerial == serial {
                    self.presentCompletion((sug ?? nil)?.text, requestedBuffer: reqBuffer)
                }
                // Always converge on the latest context.
                if again { self.scheduleGenerate() }
            }
        }
    }

    // Show a freshly generated completion, tolerating that the user may have typed
    // MORE since the request was issued: if they typed along the prediction we show
    // the remaining tail; if they diverged we regenerate.
    func presentCompletion(_ text: String?, requestedBuffer: String) {
        guard let text, !text.isEmpty else {
            if completion == nil { overlay.orderOut(nil) }
            return
        }
        // Drop completions that just repeat the text after the caret (showing only a
        // partial mid-word remainder would be confusing) — regenerate instead.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !lastTrailing.isEmpty, !trimmed.isEmpty,
           lastTrailing.hasPrefix(String(trimmed.prefix(min(trimmed.count, 12)))) {
            log("drop completion repeating trailing text"); completion = nil; overlay.orderOut(nil); return
        }
        let chars = Array(text)
        // What did the user type since the request? Robust to the 4000-char cap
        // front-truncating the buffer or an idle-reset clearing it: match on a
        // trailing anchor of the request-time buffer instead of a full hasPrefix.
        let typedSince: [Character]
        if buffer == requestedBuffer {
            typedSince = []
        } else {
            let anchor = String(requestedBuffer.suffix(80))
            if anchor.count >= 8, let r = buffer.range(of: anchor, options: .backwards) {
                typedSince = Array(buffer[r.upperBound...])
            } else if buffer.hasPrefix(requestedBuffer) {
                typedSince = Array(buffer.dropFirst(requestedBuffer.count))
            } else {
                scheduleGenerate(); return     // genuinely diverged — start over
            }
        }
        if typedSince.isEmpty {
            completion = ActiveCompletion(chars: chars)
        } else if typedSince.count < chars.count, Array(chars[0..<typedSince.count]) == typedSince {
            var comp = ActiveCompletion(chars: chars); comp.consumed = typedSince.count
            completion = comp
        } else {
            scheduleGenerate(); return         // typed off the prediction
        }
        stats.shown += 1; statsTouched()
        showCompletionRemainder(animate: true)
        maybePrefetch()
    }
}
