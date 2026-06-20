import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

final class SuggestionOverlay: NSPanel {
    private let ghost = GhostView(frame: NSRect(x: 0, y: 0, width: 420, height: 38))

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
        let fs = fontSize(for: lineHeight)
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fs), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.5)])
        place(attr, fontSize: fs, at: point, lineHeight: lineHeight, shimmer: animate)
    }

    // Inline diff for a pending correction. Spelling, and grammar with a fix, render the
    // red-strike original → green replacement. Advisory-only grammar (no replacement)
    // shows just its message in amber — Tab passes through, there's nothing to apply.
    func show(correction c: Correction, at point: NSPoint, lineHeight: CGFloat) {
        let fs = fontSize(for: lineHeight)
        let s = NSMutableAttributedString()
        if let replacement = c.replacement {
            s.append(NSAttributedString(string: c.displayOriginal, attributes: [
                .font: NSFont.systemFont(ofSize: fs),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7)]))
            s.append(NSAttributedString(string: " → " + replacement, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .semibold),
                .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.95)]))
        } else {
            // Advisory-only grammar note: amber, no green replacement glyph.
            s.append(NSAttributedString(string: c.message ?? c.displayOriginal, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .medium),
                .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.95)]))
        }
        place(s, fontSize: fs, at: point, lineHeight: lineHeight, shimmer: true)
    }

    // `point` is the caret's right edge (x) and bottom (y). The panel is the caret
    // line height, so the text is vertically centered on the caret line (inline).
    private func place(_ attr: NSAttributedString, fontSize fs: CGFloat, at point: NSPoint, lineHeight: CGFloat, shimmer: Bool) {
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
        ghost.render(attr, fontSize: fs, taperWidth: taperW, shimmer: shimmer && !wasVisible)
        if !wasVisible {
            ghost.fadeIn()
            orderFrontRegardless()
        }
    }
}
