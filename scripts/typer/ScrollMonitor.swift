import AppKit
import Foundation

// Scroll-wheel caret invalidation (spec B.4).
//
// An AX caret rect (and our cached screenshot/click anchors) goes stale the instant the
// user scrolls a long document — the ghost gets stuck on the old line until the next
// keystroke re-anchors. Cotypist watches `.scrollWheel` events for exactly this. We do
// the same: a global monitor (events delivered to other apps) plus a local monitor
// (events delivered to our own windows, which a global monitor never sees), both firing
// a debounced `onScroll` so a momentum-scroll burst collapses into a single re-anchor.
//
// Listen-only NSEvent monitors never consume the event, so this can't interfere with the
// host app's own scrolling.
final class ScrollMonitor {
    private var global: Any?
    private var local: Any?
    private let onScroll: () -> Void
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval

    init(debounce: TimeInterval = 0.06, onScroll: @escaping () -> Void) {
        self.debounce = debounce
        self.onScroll = onScroll
    }

    func start() {
        guard global == nil, local == nil else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.schedule()
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.schedule()
            return event   // never consume
        }
    }

    func stop() {
        if let g = global { NSEvent.removeMonitor(g); global = nil }
        if let l = local { NSEvent.removeMonitor(l); local = nil }
        pending?.cancel(); pending = nil
    }

    // Collapse a momentum-scroll burst into one trailing-edge re-anchor on the main loop.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onScroll() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit { stop() }
}
