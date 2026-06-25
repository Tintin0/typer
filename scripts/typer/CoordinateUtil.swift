import AppKit
import Foundation

// Centralized AX↔AppKit coordinate conversion (spec B.6).
//
// AX APIs report global coordinates with a top-left origin anchored at the top-left of
// the PRIMARY display (the menu-bar / zero-origin screen) — the same space as
// CGEvent / CGDisplayBounds. AppKit (NSPanel.setFrame, NSScreen.frame) uses a
// bottom-left origin anchored at the bottom-left of that SAME primary screen. The flip
// must therefore use the primary screen's height, NOT the height of whatever screen the
// rect happens to land on; using the local screen's maxY breaks on multi-monitor setups.
// This is the `UIElementUtilities.flippedScreenBounds:` semantics Cotypist centralizes.
//
// IMPORTANT: AX rects are in POINTS — never divide by backingScaleFactor here (that is
// only for ScreenCaptureKit / Vision pixel math).
enum CoordinateUtil {
    // The primary (zero-origin) display's max-Y, used as the flip pivot. NSScreen is
    // main-affine, so callers off the main thread must snapshot this on the main thread
    // and pass it to `flip(_:primaryMaxY:)` instead of calling this.
    static func primaryMaxY() -> CGFloat {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        return primary?.frame.maxY ?? 0
    }

    // Flip a global rect between AX (top-left) and AppKit (bottom-left), using an
    // explicitly supplied primary-screen height (safe to call off the main thread).
    @inline(__always)
    static func flip(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryMaxY - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    // Main-thread convenience: AX rect (top-left, primary-anchored) → AppKit rect.
    static func axRectToAppKit(_ rect: CGRect) -> CGRect {
        flip(rect, primaryMaxY: primaryMaxY())
    }

    // Flip a single global point (e.g. CGEvent.location) into AppKit coords.
    static func axPointToAppKit(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: primaryMaxY() - point.y)
    }
}
