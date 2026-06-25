import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Event-driven ghost re-anchoring. The fixed 90ms/280ms re-anchor timers exist
// because our event tap sees a keystroke BEFORE the host app applies it — reading
// the AX caret immediately would return a stale position. But "how long until the
// app catches up" varies per app and per moment; a timer is always either too
// early (stale read) or too late (the ghost lags). An AXObserver removes the
// guessing: the host app posts AXValueChanged/AXSelectedTextChanged the moment it
// actually applies the edit, and we re-anchor right then. The timers stay as a
// fallback for apps that don't emit AX notifications.

// Defer-release wrapper for the AXObserver (spec D.2, research/stability.md §1.3).
//
// Releasing the last reference to an `AXObserver` synchronously WHILE STILL on the
// observer's own callback stack re-enters AX framework teardown (run-loop source
// removal, port invalidation) re-entrantly — a classic deadlock / use-after-free
// vector against the WindowServer/host during rapid focus churn. Cotypist never
// releases inline: setting the slot (including to nil) captures the previous observer
// and drops it on the next main-loop turn, after the callback frame has unwound.
// We mirror that exactly. typer keeps a single observer (re-pointed per app), so one
// shared deferred slot is enough; the per-PID/per-element state stays on TyperApp.
final class DeferredAXObserver {
    static let shared = DeferredAXObserver()
    private(set) var value: AXObserver?

    // Assign the live observer; the previous one is released off the callback stack.
    func set(_ new: AXObserver?) {
        let old = value
        value = new
        if let old { DispatchQueue.main.async { _ = old } }   // release after the frame unwinds
    }
}

// Background-context debounce state (spec C.2). An AXSelectedTextChanged notification
// means the user typed/moved the caret, so the cached background is now stale — but we
// must NOT run the expensive screenshot/OCR/AX-walk synchronously on that notification.
// Instead we mark the cache dirty and schedule a single coalesced refresh ~600 ms after
// the LAST change (Cotypist's lastRefreshCheck gate). A low-frequency safety timer
// (TyperApp+Context) still covers apps that never post AX notifications. File-private so
// it lives entirely in W1B's files without adding stored props to TyperApp.swift.
private let axBackgroundDebounce: TimeInterval = 0.6
private var axLastChangeAt = Date.distantPast
private var axBackgroundRefreshScheduled = false

extension TyperApp {
    // (Re)point the observer at the frontmost app, and at its focused element.
    // Cheap when nothing changed; call freely on app switches and focus moves.
    func updateAXObserver() {
        guard AXIsProcessTrusted() else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        // Never observe our own process (Settings/onboarding windows): focus changes
        // inside a SwiftUI window fire AX callbacks that read its a11y tree and beachball
        // the main thread. Tear down and wait for a real app to come forward.
        if pid == ProcessInfo.processInfo.processIdentifier {
            if axObserverPID != 0 { teardownAXObserver(); axObserverPID = 0 }
            return
        }
        if pid != axObserverPID {
            // Focus/app change: tear down + recreate with a DEFERRED release rather than
            // un-registering per-element notifications on a possibly-dead element (D.2).
            teardownAXObserver()
            guard pid > 0 else { return }
            var obs: AXObserver?
            let cb: AXObserverCallback = { _, element, notification, refcon in
                guard let refcon else { return }
                let app = Unmanaged<TyperApp>.fromOpaque(refcon).takeUnretainedValue()
                app.handleAXNotification(notification as String, element: element)
            }
            guard AXObserverCreate(pid, cb, &obs) == .success, let obs else {
                dlog("AXObserver create failed pid=\(pid)")
                return
            }
            axObserver = obs
            DeferredAXObserver.shared.set(obs)
            axObserverPID = pid
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            // Focus changes are observed app-wide so we can re-target the per-element
            // notifications without polling. The application element is bound to the 50 ms
            // messaging timeout (D.1) so a wedged app can't stall registration.
            let appElement = axAppElement(pid)
            AXObserverAddNotification(obs, appElement, kAXFocusedUIElementChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            dlog("AXObserver attached pid=\(pid)")
        }
        refreshObservedElement()
    }

    // Subscribe to edit notifications on the CURRENT focused element (they cannot
    // be observed app-wide; AX notifications are registered per element).
    //
    // We deliberately DO NOT call AXObserverRemoveNotification on the previously
    // focused element (D.2 / research/stability.md §1.1): on a focus change that
    // element may already be dead (its app crashed/quit), and removing a notification
    // on a dead element is a known hang/crash vector. Stale per-element registrations
    // are harmless — they simply stop firing and die with the deferred observer when the
    // app changes. We only swap which element we *track* and add the new registrations.
    func refreshObservedElement() {
        guard let obs = axObserver else { return }
        let el = focusedElement()
        if let old = axObservedElement, let el, CFEqual(old, el) { return }
        axObservedElement = el
        guard let el else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, el, kAXSelectedTextChangedNotification as CFString, refcon)
    }

    func teardownAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            // Release the observer off the callback stack (deferred), never inline (D.2).
            DeferredAXObserver.shared.set(nil)
        }
        axObserver = nil
        axObservedElement = nil
        axObserverPID = 0
    }

    // Runs on the main run loop (the observer's source is scheduled there).
    func handleAXNotification(_ name: String, element: AXUIElement) {
        if name == kAXFocusedUIElementChangedNotification as String {
            refreshObservedElement()
            return
        }
        // The user typed/moved the caret: the cached background is now stale. Mark it
        // dirty and schedule ONE debounced refresh after the burst settles (C.2). The
        // expensive capture never runs on this synchronous notification path.
        if name == kAXSelectedTextChangedNotification as String {
            scheduleBackgroundRefreshDebounced()
        }
        // The app just applied an edit — its AX caret is fresh NOW. Re-anchor on
        // the next runloop tick, coalescing bursts (apps can post several
        // notifications per keystroke).
        guard completion != nil, !axNotifyPending else { return }
        axNotifyPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.axNotifyPending = false
            guard self.completion != nil else { return }
            self.showCompletionRemainder(reanchor: true)
        }
    }

    // Coalesce a flurry of AXSelectedTextChanged notifications into a single background
    // refresh ~600 ms after the last change. Marks the cache dirty so the refresh is not
    // skipped by its time-throttle, then fires it once the user pauses (C.2). Cheap and
    // main-thread only; the heavy work is dispatched off-main inside refreshBackgroundIfNeeded.
    func scheduleBackgroundRefreshDebounced() {
        axLastChangeAt = Date()
        guard !axBackgroundRefreshScheduled else { return }
        axBackgroundRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + axBackgroundDebounce) { [weak self] in
            axBackgroundRefreshScheduled = false
            guard let self else { return }
            // If more changes arrived during the window, wait for the next pause.
            if Date().timeIntervalSince(axLastChangeAt) < axBackgroundDebounce - 0.05 {
                self.scheduleBackgroundRefreshDebounced()
                return
            }
            // Event-driven refresh: bypass the time-throttle (the user just paused after
            // editing, which is exactly when fresh background helps) but still single-flight.
            self.refreshBackgroundIfNeeded(force: true)
        }
    }
}
