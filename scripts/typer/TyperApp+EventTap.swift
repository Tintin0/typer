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
    func handlePointerInteraction() {
        syncActiveApp()
        generationSerial &+= 1
        debounce?.invalidate(); debounce = nil
        clearSuggestion()
        lastTrailing = ""
        caretHeightFloor = nil
        if cfg.styleMemoryEnabled { styleMemory.record(buffer) }
        let serial = generationSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.generationSerial == serial else { return } // typing happened; leave it alone
            self.syncActiveApp()
            if let ax = self.textAroundCursor(limit: 500), !ax.before.isEmpty {
                self.buffer = String(ax.before.suffix(500))
            } else {
                self.buffer = ""
            }
            self.saveActiveAppState()
            self.lastCaretPoint = self.caretPoint()
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
            handlePointerInteraction()
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
        if code == CGKeyCode(kVK_Escape) { clearSuggestion(); return }
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
                if cfg.styleMemoryEnabled { styleMemory.record(buffer) }
                buffer = ""; saveActiveAppState(); clearSuggestion()
            }
            return
        }
        if hasCommandLikeModifier { return }
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
            if completion != nil { completion = nil; prefetched = nil; prefetchKey = ""; overlay.orderOut(nil) }
            presentTypo(word: word, fix: fix)
            return
        }
        if completion != nil {
            if followAlong(text) { return }   // typed exactly what we predicted — keep it
            // deviated from the prediction: drop it and any speculative prefetch
            completion = nil
            prefetched = nil
            prefetchKey = ""
            overlay.orderOut(nil)
            // (No per-keystroke "ignored" counter — it over-counted natural typing.
            //  Accept rate is accepted/shown, which is the meaningful signal.)
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
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate() }
        } else {
            // Move the ghost immediately by the measured width of what was typed (the
            // app hasn't applied the keystroke yet, so a synchronous AX read would be
            // stale and overlap). A coalesced deferred re-anchor then corrects drift
            // and line-wrap once the app has caught up.
            if let p = lastCaretPoint { lastCaretPoint = NSPoint(x: p.x + ghostWidth(text), y: p.y) }
            showCompletionRemainder(reanchor: false)
            scheduleReanchor()
            maybePrefetch()
        }
        return true
    }
}
