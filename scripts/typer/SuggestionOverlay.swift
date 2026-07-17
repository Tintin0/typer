import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Named correction colors (#8, spec E §8). Mirrors Cotypist's asset colors
// `autocorrectStrikethroughRed` / `autocorrectCorrectionGreen`: the typo is struck through in
// red, the suggested fix drawn in green right after it. Kept as one place so the overlay and
// any future candidate picker render the diff identically. Dynamic so they read correctly in
// light and dark appearances.
enum CorrectionColors {
    static let strikethroughRed = NSColor(name: "autocorrectStrikethroughRed") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.16, blue: 0.13, alpha: 1)
    }
    static let correctionGreen = NSColor(name: "autocorrectCorrectionGreen") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.86, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.62, blue: 0.30, alpha: 1)
    }
    // Advisory grammar notes (no machine-applicable fix): amber, distinct from a real fix.
    static let advisoryAmber = NSColor.systemOrange
    // Inline completion ghost: ultramarine blue (replaces the faint host-matched grey). Deeper
    // on a light background, brighter on dark, so it stays legible in either appearance.
    static let ghostUltramarine = NSColor(name: "ghostUltramarine") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.46, green: 0.56, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.20, blue: 0.80, alpha: 1)
    }
}

final class SuggestionOverlay: NSPanel {
    private let ghost = GhostView(frame: NSRect(x: 0, y: 0, width: 420, height: 38))

    // The host field's real font/color, read over AX (spec B.2) by the caret subsystem
    // and stashed here just before placement. When set, the inline ghost renders in the
    // host typography instead of NSFont.systemFont, which is what removes fast-typing
    // horizontal drift on monospace/condensed/proportional fonts. nil = system fallback.
    var pendingHostFont: NSFont?
    var pendingHostColor: NSColor?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = ghost
        orderOut(nil)
    }

    private func fontSize(for lineHeight: CGFloat) -> CGFloat { min(max(lineHeight * 0.62, 11), 30) }

    func showCompletion(_ text: String, at point: NSPoint, lineHeight: CGFloat, animate: Bool) {
        // Prefer the host font (B.2); fall back to the system font sized to the caret line.
        let font = pendingHostFont ?? NSFont.systemFont(ofSize: fontSize(for: lineHeight))
        let fs = font.pointSize
        // Keep the host FONT (so the ghost sits inline) but render it in ultramarine blue, not
        // the host text colour — the colour is the point. Alpha < 1 keeps it clearly a suggestion.
        let attr = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CorrectionColors.ghostUltramarine.withAlphaComponent(0.85)])
        place(attr, fontSize: fs, font: font, at: point, lineHeight: lineHeight, shimmer: animate)
    }

    // Inline diff for a pending correction. Spelling, and grammar with a fix, render the
    // red-strike original → green replacement. Advisory-only grammar (no replacement)
    // shows just its message in amber — Tab passes through, there's nothing to apply.
    func show(correction c: Correction, at point: NSPoint, lineHeight: CGFloat) {
        let fs = fontSize(for: lineHeight)
        let s = NSMutableAttributedString()
        if let replacement = c.replacement {
            // Typo struck through in red, fix in green right after — the named-color diff (#8).
            s.append(NSAttributedString(string: c.displayOriginal, attributes: [
                .font: NSFont.systemFont(ofSize: fs),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: CorrectionColors.strikethroughRed,
                .foregroundColor: CorrectionColors.strikethroughRed.withAlphaComponent(0.75)]))
            s.append(NSAttributedString(string: " → " + replacement, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .semibold),
                .foregroundColor: CorrectionColors.correctionGreen]))
        } else {
            // Advisory-only grammar note: amber, no green replacement glyph.
            s.append(NSAttributedString(string: c.message ?? c.displayOriginal, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .medium),
                .foregroundColor: CorrectionColors.advisoryAmber.withAlphaComponent(0.95)]))
        }
        place(s, fontSize: fs, font: NSFont.systemFont(ofSize: fs), at: point, lineHeight: lineHeight, shimmer: true)
    }

    // `point` is the caret's right edge (x) and bottom (y). The panel is the caret
    // line height, so the text is vertically centered on the caret line (inline).
    private func place(_ attr: NSAttributedString, fontSize fs: CGFloat, font: NSFont, at point: NSPoint, lineHeight: CGFloat, shimmer: Bool) {
        let textW = ceil(attr.size().width)
        let taperW: CGFloat = 20
        let w = min(textW + 8, 760)
        let h = max(lineHeight, 14)
        var frame = NSRect(x: point.x, y: point.y, width: w, height: h)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let v = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.origin.x, v.minX), v.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, v.minY), v.maxY - frame.height)
        }
        let wasVisible = isVisible
        setFrame(frame, display: true)
        ghost.frame = NSRect(origin: .zero, size: frame.size)
        // Shimmer only on a genuinely fresh appearance — never while streaming updates
        // or shrinking as the user types through it.
        ghost.render(attr, fontSize: fs, font: font, taperWidth: taperW, shimmer: shimmer && !wasVisible)
        if !wasVisible {
            ghost.fadeIn()
            orderFrontRegardless()
        }
    }
}
