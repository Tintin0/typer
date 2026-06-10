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
extension TyperApp {
    // (Re)point the observer at the frontmost app, and at its focused element.
    // Cheap when nothing changed; call freely on app switches and focus moves.
    func updateAXObserver() {
        guard AXIsProcessTrusted() else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != axObserverPID {
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
            axObserverPID = pid
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            // Focus changes are observed app-wide so we can re-target the per-element
            // notifications without polling.
            let appElement = AXUIElementCreateApplication(pid)
            AXObserverAddNotification(obs, appElement, kAXFocusedUIElementChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            dlog("AXObserver attached pid=\(pid)")
        }
        refreshObservedElement()
    }

    // Subscribe to edit notifications on the CURRENT focused element (they cannot
    // be observed app-wide; AX notifications are registered per element).
    func refreshObservedElement() {
        guard let obs = axObserver else { return }
        let el = focusedElement()
        if let old = axObservedElement, let el, CFEqual(old, el) { return }
        if let old = axObservedElement {
            AXObserverRemoveNotification(obs, old, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(obs, old, kAXSelectedTextChangedNotification as CFString)
        }
        axObservedElement = el
        guard let el else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, el, kAXSelectedTextChangedNotification as CFString, refcon)
    }

    func teardownAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
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
}
