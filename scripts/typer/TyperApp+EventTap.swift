import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    func setupEventTap() {
        let disableMask = (1 << CGEventType.tapDisabledByTimeout.rawValue) | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        // Observer: listen-only at the head. Listen-only taps do NOT gate event
        // delivery on the callback returning, so a slow main thread can never stall
        // global keystrokes in other apps. This watches typing and builds state.
        let observerMask = (1 << CGEventType.keyDown.rawValue) |
                           (1 << CGEventType.leftMouseDown.rawValue) |
                           (1 << CGEventType.rightMouseDown.rawValue) |
                           (1 << CGEventType.otherMouseDown.rawValue) |
                           disableMask
        let observerCB: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue().observe(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        observerTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: CGEventMask(observerMask),
                                        callback: observerCB, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let observerTap else {
            log("ERROR observer tap creation failed; Accessibility permission likely missing for Typer.app")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observerTap, 0), .commonModes)
        CGEvent.tapEnable(tap: observerTap, enable: true)

        // Accept tap: a consuming .defaultTap at the tail that only grabs Tab/backtick.
        // It is enabled ONLY while a suggestion is visible (refreshAcceptTap), so when
        // nothing is showing Typer consumes no keys at all.
        let acceptMask = (1 << CGEventType.keyDown.rawValue) | disableMask
        let acceptCB: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue().accept(type: type, event: event)
        }
        acceptTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                      options: .defaultTap, eventsOfInterest: CGEventMask(acceptMask),
                                      callback: acceptCB, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let acceptTap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, acceptTap, 0), .commonModes)
            CGEvent.tapEnable(tap: acceptTap, enable: false)   // off until a suggestion shows
        }
        log("event taps installed (observer + accept)")
    }

    // Enable the consuming accept tap exactly while a suggestion is on screen.
    // Idempotent: each CGEvent.tapEnable is a BLOCKING mach round-trip to the
    // WindowServer, so calling it redundantly (e.g. on every tapDisabled echo) burns a
    // whole CPU core. Only touch the tap when the desired state actually changes.
    func refreshAcceptTap() {
        guard let acceptTap else { return }
        let want = completion != nil || active != nil || Date() < acceptGraceUntil
        if want == acceptTapEnabled { return }
        acceptTapEnabled = want
        CGEvent.tapEnable(tap: acceptTap, enable: want)
    }

    // Hold the accept tap open briefly after an accept exhausts the suggestion. Without
    // this, the tap tears down the instant completion=nil, and the second of two rapid
    // Tabs leaks to the host app — tabbing focus out of the field or inserting a literal
    // tab right where the user was accepting words. The trailing refresh releases the
    // tap once the grace expires (nothing else fires refreshAcceptTap on a timer).
    func armAcceptGrace(_ interval: TimeInterval = 0.35) {
        acceptGraceUntil = Date().addingTimeInterval(interval)
        refreshAcceptTap()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval + 0.05) { [weak self] in
            self?.refreshAcceptTap()
        }
    }

    private func reEnable(_ tap: CFMachPort?, _ label: String) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        log("\(label) tap re-enabled")
    }

    // A mouse click is a cursor/focus change, not typing. Clear anything pending,
    // invalidate in-flight generations, and warm the context cache after the target
    // app has processed the click — but never schedule a completion from the click.
    // A left-click also places the text caret at the click point; record it as a cheap
    // caret seed for AX-hostile fields (see currentCaretPoint's click-anchor branch).
    func handlePointerInteraction(at location: CGPoint? = nil) {
        if cfg.clickCaretEnabled, let location { recordClickCaret(at: location) }
        invalidateAndResync()
        refreshObservedElement()    // a click usually moves keyboard focus too
    }

    // Shared "the text changed underneath us" path: a click moved the cursor, or a
    // ⌘V/⌘X/⌘Z mutated the field outside our keystroke view. Duck out instantly
    // (the ghost must never sit over text we did not predict), then re-sync the
    // buffer from AX once the host app has applied the change.
    func invalidateAndResync() {
        syncActiveApp()
        generationSerial &+= 1
        debounce?.invalidate(); debounce = nil
        clearSuggestion()
        lastTrailing = ""
        caretHeightFloor = nil
        recordLearning()
        let serial = generationSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            // Clear the click-pending flag in every exit path. If typing raced in before
            // this resync (serial advanced), the buffer was never reset, so a click anchor
            // can't be baselined coherently — abandon it rather than leave a half-stamped
            // one that would misplace the ghost.
            let clickPending = self.clickCaretPending
            self.clickCaretPending = false
            guard self.generationSerial == serial else {   // typing happened; leave it alone
                if clickPending { self.clickCaretPoint = nil; self.clickCaretApp = "" }
                return
            }
            self.syncActiveApp()
            if let ax = self.textAroundCursor(limit: 500), !ax.before.isEmpty {
                self.buffer = String(ax.before.suffix(500))
            } else {
                self.buffer = ""
            }
            // Resynced text wasn't necessarily typed by the user (it may be pasted or
            // pre-existing) — the lexicon only learns from real typing, so mark the
            // whole buffer as already seen.
            self.lexiconWatermark[self.activeAppKey] = self.buffer.count
            self.saveActiveAppState()
            self.lastCaretPoint = self.caretPoint()
            // If this resync followed a fresh left-click (pending flag), stamp the click
            // anchor to the just-synced active app, baselined at the current buffer length
            // so typed-width extrapolation starts from zero. The flag (not a time window)
            // ensures a paste/⌘Z resync never re-baselines a stale anchor.
            if self.cfg.clickCaretEnabled, clickPending, self.clickCaretPoint != nil {
                self.clickCaretApp = self.activeAppKey
                self.clickCaretBufferLen = self.buffer.count
            }
            self.refreshBackgroundIfNeeded()
        }
    }

    // Listen-only: observes typing, builds the buffer, drives generation. Never
    // consumes Tab/backtick (the accept tap does that).
    func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { reEnable(observerTap, "observer"); return }
        if IsSecureEventInputEnabled() {                 // never capture during secure input
            if completion != nil || active != nil { clearSuggestion() }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return }  // our own insertion
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // Only a left-click reliably places the text caret; right/other clicks open
            // menus and shouldn't seed a caret anchor.
            handlePointerInteraction(at: type == .leftMouseDown ? event.location : nil)
            return
        }
        guard type == .keyDown else { return }
        syncActiveApp()
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // event.flags already carries the live modifier state for this keyDown, so we
        // don't track Shift/Command/Control/Option ourselves (and the observer tap no
        // longer needs keyUp events at all).
        let flags = event.flags
        let hasCommandLikeModifier = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

        if code == CGKeyCode(kVK_Tab) { return }         // accept tap handles Tab
        if code == CGKeyCode(kVK_ANSI_Grave) {
            // Backtick is "accept all" while a suggestion shows (accept tap consumes
            // it); otherwise it's a literal character the user is typing.
            if completion != nil || active != nil { return }
        }
        if code == CGKeyCode(kVK_Escape) {
            // Esc with a suggestion showing is an explicit rejection — feed it back.
            if let comp = completion { resolveCompletionOutcome(comp, via: "none") }
            rejectActiveTypo()      // a dismissed spelling fix: count it, optionally stop re-suggesting
            clearSuggestion(); return
        }
        if code == CGKeyCode(kVK_Delete) {
            generationSerial &+= 1
            lastUserTypedAt = Date()
            if !buffer.isEmpty { buffer.removeLast() }
            saveActiveAppState(); clearSuggestion(); scheduleGenerate(); return
        }
        if code == CGKeyCode(kVK_Return) {
            generationSerial &+= 1
            lastUserTypedAt = Date()
            if flags.contains(.maskShift) { push("\n", countsAsUserTyping: false) } else {
                recordLearning()
                buffer = ""; lexiconWatermark[activeAppKey] = 0
                saveActiveAppState(); clearSuggestion()
            }
            return
        }
        if hasCommandLikeModifier {
            // ⌘V/⌘X/⌘Z mutate the field's text outside our keystroke view. Duck out
            // immediately — the ghost would otherwise sit stale on top of the pasted
            // text — and re-sync the buffer from AX so the next generation builds on
            // what is actually in the field (pasted content included).
            if flags.contains(.maskCommand),
               code == CGKeyCode(kVK_ANSI_V) || code == CGKeyCode(kVK_ANSI_X) || code == CGKeyCode(kVK_ANSI_Z) {
                dlog("[\(activeAppKey)] external edit shortcut code=\(code) — resync")
                invalidateAndResync()
            }
            return
        }
        if let chars = event.keyboardString, !chars.isEmpty {
            dlog("[\(activeAppKey)] key code=\(code)")
            handleTyping(chars)
        }
    }

    // Consuming tap, enabled only while a suggestion is visible: grabs Tab/backtick.
    func accept(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-arm ONLY if a suggestion is actually showing. A tapDisabled notification
        // while nothing is up is our own tapEnable(false) echoing back — re-enabling
        // here (a blocking mach call) would spin a whole CPU core indefinitely.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if completion != nil || active != nil || Date() < acceptGraceUntil {
                acceptTapEnabled = true
                if let acceptTap { CGEvent.tapEnable(tap: acceptTap, enable: true) }
            } else {
                acceptTapEnabled = false
            }
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return Unmanaged.passUnretained(event) }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if code == CGKeyCode(kVK_Tab) {
            if acceptCompletionWord() { return nil }
            if acceptOneWord() { return nil }
            // A Tab in the grace window right after an accept exhausted the suggestion
            // is the user asking for MORE, not a focus change — swallow it. Keep the
            // window open while the next chunk is actually on its way, so Tab-mashing
            // through a generation never tabs out of the field.
            if Date() < acceptGraceUntil {
                if requestInFlight || (debounce?.isValid ?? false) { armAcceptGrace() }
                return nil
            }
        } else if code == CGKeyCode(kVK_ANSI_Grave) {
            if acceptCompletionAll() { return nil }
            if acceptAll() { return nil }
        }
        return Unmanaged.passUnretained(event)
    }

    // Core "type as fast as you think" path. The user's keystroke passes through to
    // the app regardless; here we decide whether it matches the live prediction
    // (keep it, just shrink the ghost) or deviates (regenerate).
    func handleTyping(_ text: String) {
        generationSerial &+= 1
        lastUserTypedAt = Date()
        acceptGraceUntil = .distantPast   // typed a real character — moved on; a Tab now is a real Tab
        appendToBuffer(text)
        // A just-finished misspelled word takes priority over following a live
        // completion: typing the separator that ends "peopel" should surface the fix,
        // not get swallowed as "you typed along with the ghost". Only fires when the
        // word is actually misspelled, so correctly-spelled type-along is untouched.
        if cfg.typoEnabled, text.unicodeScalars.allSatisfy({ isWordSeparator($0) }),
           let word = lastWordFromBuffer(), let fix = correction(for: word) {
            // Resolve the on-screen completion's outcome before dropping it for the typo fix,
            // the same way the divergence path below does — otherwise its accept/reject signal
            // never reaches the model race, adaptive feedback, or training log, and its pending
            // training example is silently overwritten by the next suggestion (issue #3).
            if let comp = completion {
                resolveCompletionOutcome(comp, via: comp.consumed > 0 ? "typethrough" : "none")
                completion = nil; prefetched = nil; prefetchKey = ""; overlay.orderOut(nil)
            }
            presentTypo(word: word, fix: fix)
            return
        }
        // Grammar runs on sentence-terminating separators only (. ! ? newline), parallel
        // to the typo branch but lower priority (spelling fired first above). OFF by
        // default. The flagged span's exact AX range is resolved from the sentence's
        // UTF-16 offset, so apply() needs no backward word scan.
        if cfg.grammarEnabled, text.unicodeScalars.allSatisfy({ ".!?\n\r".unicodeScalars.contains($0) }) {
            if let ax = textAroundCursor(limit: 500), !ax.before.isEmpty {
                let before = ax.before as NSString
                // The sentence just completed: from the last sentence boundary to the caret.
                let sentence = lastSentence(in: ax.before)
                let startUTF16 = before.length - (sentence as NSString).length
                // Resolve the live completion's outcome before tearing it down for grammar,
                // exactly as the typo branch above does (issue #3): its accept/reject signal
                // must reach the race / feedback / training log, not be silently dropped.
                if let comp = completion {
                    resolveCompletionOutcome(comp, via: comp.consumed > 0 ? "typethrough" : "none")
                    completion = nil; prefetched = nil; prefetchKey = ""; overlay.orderOut(nil)
                }
                grammarCorrections(in: sentence, sentenceStartUTF16: startUTF16)
                // Detection is async; it presents only if nothing is showing. Fall through
                // so a completion can still be scheduled if grammar finds nothing.
            }
        }
        if let comp = completion {
            if followAlong(text) { return }   // typed exactly what we predicted — keep it
            // Deviated from the prediction: an implicit rejection (or partial use, if
            // some words were consumed first). Feed it back, then drop the prediction
            // and any speculative prefetch.
            resolveCompletionOutcome(comp, via: comp.consumed > 0 ? "typethrough" : "none")
            completion = nil
            prefetched = nil
            prefetchKey = ""
            overlay.orderOut(nil)
        }
        scheduleGenerate()
    }

    // Returns true if every character of `text` matched the next predicted
    // character, advancing the consumed prefix instead of regenerating.
    func followAlong(_ text: String) -> Bool {
        guard var comp = completion else { return false }
        for ch in text {
            guard comp.consumed < comp.chars.count, comp.chars[comp.consumed] == ch else { return false }
            comp.consumed += 1
        }
        completion = comp
        if comp.done {
            // Typed all the way through — a strong "this matched my intent" signal.
            stats.accepted += 1; statsTouched()
            resolveCompletionOutcome(comp, via: "typethrough")
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate() }
        } else {
            // Move the ghost immediately by the measured width of what was typed (the
            // app hasn't applied the keystroke yet, so a synchronous AX read would be
            // stale and overlap). A coalesced deferred re-anchor then corrects drift
            // and line-wrap once the app has caught up.
            advanceGhost(by: text)
            showCompletionRemainder(reanchor: false)
            scheduleReanchor()
            maybePrefetch()
        }
        return true
    }
}
