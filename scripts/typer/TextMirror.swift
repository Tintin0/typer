import AppKit
import Foundation

// TextMirror fallback (spec B.3) — a deterministic, font-exact caret for AX-hostile
// fields (Google Docs canvas, some Electron/Catalyst fields, anything that exposes text +
// a caret CHARACTER INDEX but no usable pixel caret rect).
//
// We rebuild the host text around the caret in our own TextKit stack, lay it out with the
// host's font, then ask the layout manager for the exact glyph rect at the caret index.
// That needs only (text, caret char index, font) — three things almost every app exposes
// — instead of a pixel caret rect many apps don't. The cost is that the suggestion shows
// in a small floating window anchored to the field rather than literally inside it, so we
// show a one-time banner telling the user to keep typing in the real field.

// The TextKit-backed view: lays out text and reports the caret glyph rect.
final class TextMirrorView: NSView {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer()
    var cursorPosition = 0                       // caret as a CHARACTER INDEX, not a pixel
    private let caretLayer = CALayer()
    private(set) var caretLineHeight: CGFloat = 18
    var textContainerInset = NSSize(width: 6, height: 4)

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        caretLayer.backgroundColor = NSColor.textColor.cgColor
        layer?.addSublayer(caretLayer)
    }

    override var isFlipped: Bool { true }   // top-left origin matches TextKit glyph coords

    // Rebuild the mirrored content. `text` is the host text around the caret, `caret` is
    // the caret's character index INTO that text, and `suggestion` is the ghost remainder
    // appended after the caret (dimmed). Font/color come from the host element (B.2).
    func update(text: String, caret: Int, suggestion: String, font: NSFont, color: NSColor) {
        let safeCaret = max(0, min(caret, (text as NSString).length))
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color])
        if !suggestion.isEmpty {
            let ghost = NSAttributedString(string: suggestion, attributes: [
                .font: font, .foregroundColor: color.withAlphaComponent(0.5)])
            attr.insert(ghost, at: safeCaret)
        }
        textStorage.setAttributedString(attr)
        cursorPosition = safeCaret
        caretLineHeight = layoutManager.defaultLineHeight(for: font)
        textContainer.size = NSSize(width: max(40, bounds.width - textContainerInset.width * 2),
                                    height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        positionCaret()
        needsDisplay = true
    }

    // The caret glyph rect inside the mirror, in this view's (flipped) coordinates.
    func caretRectInMirror() -> CGRect {
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: cursorPosition)
        var eff = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: min(glyph, max(0, layoutManager.numberOfGlyphs - 1)),
                                                  effectiveRange: &eff)
        let loc = layoutManager.location(forGlyphAt: min(glyph, max(0, layoutManager.numberOfGlyphs - 1)))
        return CGRect(x: line.minX + loc.x + textContainerInset.width,
                      y: line.minY + textContainerInset.height,
                      width: 1.5,
                      height: line.height > 0 ? line.height : caretLineHeight)
    }

    private func positionCaret() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        caretLayer.frame = caretRectInMirror()
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
    }
}

// The borderless overlay window hosting the mirror, anchored to the host field's frame.
final class TextMirrorWindow: NSPanel {
    let mirrorView: TextMirrorView
    private let banner = NSTextField(labelWithString: "Mirror preview — keep typing in the field")
    private var bannerShown = false

    init() {
        mirrorView = TextMirrorView(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        let container = NSView(frame: contentRect(forFrameRect: frame))
        container.autoresizingMask = [.width, .height]
        container.addSubview(mirrorView)
        banner.font = .systemFont(ofSize: 9, weight: .medium)
        banner.textColor = .secondaryLabelColor
        banner.isHidden = true
        container.addSubview(banner)
        contentView = container
        orderOut(nil)
    }

    // Lay the mirror out at `fieldRect` (AppKit coords, the host field's frame) and show
    // it. `text`/`caret`/`suggestion` drive the content; `font`/`color` come from the host
    // element (B.2). `vOffset` is the per-app verticalAlignmentOffset.
    func present(fieldRect: NSRect, text: String, caret: Int, suggestion: String,
                 font: NSFont, color: NSColor, vOffset: CGFloat) {
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        // Size to a single comfortable line; cap width to the field (or a sane max).
        let width = min(max(fieldRect.width, 200), 720)
        let bannerH: CGFloat = bannerShown ? 0 : 13
        let height = lineH + mirrorView.textContainerInset.height * 2 + bannerH
        mirrorView.frame = NSRect(x: 0, y: bannerH, width: width, height: lineH + mirrorView.textContainerInset.height * 2)
        mirrorView.update(text: text, caret: caret, suggestion: suggestion, font: font, color: color)

        // Anchor just below the field's top-left text origin, nudged by the per-app offset.
        var frame = NSRect(x: fieldRect.minX, y: fieldRect.maxY - height + vOffset, width: width, height: height)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let v = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.origin.x, v.minX), v.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, v.minY), v.maxY - frame.height)
        }
        if !bannerShown {
            banner.frame = NSRect(x: 6, y: 0, width: width - 12, height: 12)
            banner.isHidden = false
        }
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    // The mirror has been shown at least once this session — drop the banner next time so
    // it doesn't keep stealing a line. (Matches Cotypist's one-time info banner.)
    func markBannerSeen() { bannerShown = true; banner.isHidden = true }

    func dismiss() { orderOut(nil) }
}
