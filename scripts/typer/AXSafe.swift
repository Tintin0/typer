import ApplicationServices
import Foundation

// Bounded, crash-resistant Accessibility reads (spec D.1).
//
// typer has zero `AXUIElementSetMessagingTimeout` calls today, so a hung host
// (Electron/IDE) can stall the main thread on a synchronous AX round-trip — the
// "freezes in app X" gripe. Every AX element typer reads from should have a 50 ms
// messaging timeout set on it (Cotypist-style) and every read should treat
// `kAXErrorCannotComplete` as "skip this tick," never block.
//
// These are free functions (shared across Caret/Context/AXObserver, which are owned
// by different waves) so any wave can call them without reaching into another's file.

// The Cotypist-style per-element messaging timeout. 50 ms is long enough for a healthy
// app to answer and short enough that a wedged one can't stall the run loop.
let kAXMessagingTimeout: Float = 0.05

// Apply the standard 50 ms messaging timeout to an AX element used for reads. Call this
// on every app/system-wide/element handle right after you create or fetch it.
@inline(__always) func axBound(_ el: AXUIElement) -> AXUIElement {
    AXUIElementSetMessagingTimeout(el, kAXMessagingTimeout)
    return el
}

// Bounded copy of a plain attribute. Returns nil on any non-success status (timeouts,
// `cannotComplete`, missing attribute), so callers can simply skip this tick.
@inline(__always) func axRead(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

// Typed convenience for the common string-attribute case.
@inline(__always) func axString(_ el: AXUIElement, _ attr: String) -> String? {
    axRead(el, attr) as? String
}

// Bounded copy of a parameterized attribute (e.g. AXBoundsForRange). Returns nil on any
// non-success status.
@inline(__always) func axReadParam(_ el: AXUIElement, _ attr: String, _ param: CFTypeRef) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, param, &v) == .success ? v : nil
}

// The focused element of an app element (already bound), itself bound to the timeout.
@inline(__always) func axFocusedElement(of appEl: AXUIElement) -> AXUIElement? {
    guard let v = axRead(appEl, kAXFocusedUIElementAttribute as String) else { return nil }
    // CFTypeRef carrying an AXUIElement (same bridge the rest of the codebase uses).
    guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return axBound(v as! AXUIElement)
}

// A bound application-scoped AX element for a pid.
@inline(__always) func axAppElement(_ pid: pid_t) -> AXUIElement {
    axBound(AXUIElementCreateApplication(pid))
}

// A bound system-wide AX element.
@inline(__always) func axSystemWideElement() -> AXUIElement {
    axBound(AXUIElementCreateSystemWide())
}
