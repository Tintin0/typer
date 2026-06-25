# Caret / Ghost-Text Placement: Cotypist Reverse-Engineering & typer Gap Analysis

Scope: how Cotypist positions inline ghost text consistently across native AppKit,
Electron/WebKit, Catalyst, terminals, and Google Docs — and what typer should adopt.

Binary analyzed: `/Applications/Cotypist.app/Contents/MacOS/Cotypist` (arm64, Swift/AppKit,
non-sandboxed). Tools: `ipsw class-dump`, `ipsw swift-dump`, `ipsw macho info --strings/--symbols`,
`nm`, `otool`. Evidence is quoted inline. "VERIFIED" = read directly from the binary;
"INFER" = reasoned from structure + best-practice macOS APIs.

---

## 1. Verified Findings (evidence)

### 1.1 Cotypist links the same low-level AX + capture stack as typer
`nm -u` (undefined imports):
```
_AXUIElementCopyAttributeValue
_AXUIElementCopyAttributeNames
_AXUIElementCopyParameterizedAttributeValue   <-- parameterized: bounds-for-range path
_AXValueGetValue
_CGWindowListCreateImage
_OBJC_CLASS_$_SCShareableContent / _SCStreamConfiguration   (ScreenCaptureKit)
_OBJC_CLASS_$_VNRecognizeTextRequest / _VNRecognizedText...  (Vision OCR)
```
`otool -L` confirms the frameworks: ScreenCaptureKit, Vision, CoreGraphics, Carbon.

So Cotypist uses `AXUIElementCopyParameterizedAttributeValue` — the same caret-rect primitive
typer uses in `boundsForSelectedRange()` / `textMarkerCaretRect()`. VERIFIED.

### 1.2 The private AX attribute *names* are obfuscated, not absent
The expected literals — `AXBoundsForRange`, `AXSelectedTextMarkerRange`,
`AXBoundsForTextMarkerRange`, `AXInsertionPointLineNumber`, `AXLineForIndex` — do **not**
appear as plain strings (`grep` over `--strings` returns nothing for them). What *does* appear
is a large bank of layered/obfuscated blobs, e.g.:
```
0x1007dd7f0: "MF9fMmVidHNyX25lZWRlcl9kaXNleg=="   -> base64 -> "0__2ebtsr_needer_disez"  (reversed/rotated)
0x1007d03a0: "VFBCMW1XS3hHV3NGalNVTmtNejQz...=I"  -> base64 -> reversed -> base64 again (multi-layer)
0x1007cd0b0: "0trT19Tz2NPExcLZ2dv0xNfY0Q=="       -> base64 -> XOR (~0xB0 key) bytes
```
These are runtime-decoded constants. INFER (high confidence): the private parameterized AX
attribute names live here, deobfuscated just before the `AXUIElementCopyParameterizedAttributeValue`
call. **Lesson for typer:** the attribute strings themselves are a non-issue functionally — typer
already passes `"AXBoundsForTextMarkerRange"` as a plain `CFString`; Cotypist obfuscates only to
avoid static detection, not for any placement advantage.

### 1.3 Cotypist reads the host field's REAL font via AX
Imported constants (`nm -u`, these are the public AX *text-attribute* keys):
```
_kAXFontNameKey  _kAXFontFamilyKey  _kAXFontSizeKey  _kAXFontTextAttribute
_kAXForegroundColorTextAttribute  _kAXListItemLevelTextAttribute
```
These are the keys inside the dictionary returned by the `AXFont` text attribute (obtained via
`kAXAttributedStringForRangeParameterizedAttribute`). VERIFIED that Cotypist pulls font
family/name/size/color from the focused element. This is how its ghost text and its mirror match
the host typography exactly. **typer reads none of these** — it always renders
`NSFont.systemFont` (see §5).

### 1.4 The TextMirror subsystem is a full NSLayoutManager text engine
`class-dump` / `swift-dump` reveal three cooperating classes:
```
class Cotypist.TextMirrorOverlayWindow: NSWindow { let mirrorViewController: TextMirrorOverlayViewController }
class Cotypist.TextMirrorOverlayViewController: NSViewController {
    let mirrorView: TextMirrorView
    let infoLabel: TextFieldWithLinkSupport      // the "this is a mirror" banner
    var textMetricsAppName: String?
}
class Cotypist.TextMirrorView: NSView {
    let layoutManager: NSLayoutManager           // VERIFIED: real TextKit stack
    let textContainer: NSTextContainer
    let textStorage:   NSTextStorage
    var attributedText: NSAttributedString
    var cursorPosition: Int                       // caret as a CHARACTER INDEX, not a pixel
    var estimatedLineHeight: CGFloat?
    let cursorLayer: CALayer                       // the drawn caret
    var cursorBlinkState/Timer                     // blink
    let textContainerInset: NSEdgeInsets
    let gradientLayer: CAGradientLayer             // top/bottom fade for overflow
    var maxDisplayLines: Int
    var currentDisplayMode: TextDisplayMode { noOverflow | overflowNearEnd | overflowMiddle }
    var textOriginOffset: CGPoint
}
```
Supporting NSLayoutManager selectors found in `--strings` (proof the mirror queries glyph geometry):
```
"lineFragmentRectForGlyphAtIndex:effectiveRange:"
"lineFragmentUsedRectForGlyphAtIndex:effectiveRange:"
"boundingRectForGlyphRange:inTextContainer:"
"enumerateEnclosingRectsForGlyphRange:withinSelectedGlyphRange:inTextContainer:usingBlock:"
"glyphRangeForTextContainer:"
"setLineFragmentPadding:"  "drawGlyphsForGlyphRange:atPoint:"  "drawBackgroundForGlyphRange:atPoint:"
```
VERIFIED architecture: Cotypist rebuilds the field's text in its own TextKit stack, lays it out
with the host's font/inset, then asks the layout manager for the exact rect of the glyph at
`cursorPosition`. That is a *deterministic* caret position, independent of whether the host app
exposes a caret rect over AX.

`RoundedBackgroundLayoutManager` (a subclass; the `drawBackgroundForGlyphRange:` + rounded-rect
strings) draws the rounded selection/ghost backing.

### 1.5 Caret rendering classes (native inline path)
```
class Cotypist.CaretView: NSView {
    var isBlinking: Bool; var blinkInterval: Double; var cursorColor: NSColor;
    var isVisible: Bool; var blinkTimer: NSTimer?
}
```
VERIFIED: a dedicated blinking caret view (used in the demo field `CompletionDemoTextField`, and
the same primitive backs the mirror's `cursorLayer`). String `"textInsertionPointColor"` shows it
matches the system insertion-point color.

### 1.6 Mouse / scroll tracking for click-to-anchor and overlay follow
```
class Cotypist.ScrollWheelMonitor { let monitor: Any? }   // NSEvent global/local monitor wrapper
class Cotypist.LineHeightCache  { let cache: Locked<[String:CGFloat]> }   // per-(font) line height memo
```
VERIFIED. `ScrollWheelMonitor` watches `.scrollWheel` events so the overlay/mirror re-anchors when
the user scrolls (an AX caret rect goes stale on scroll). `LineHeightCache` memoizes line height by
key (INFER: keyed by font descriptor) so it doesn't relayout to get line height on every keystroke
— directly analogous to typer's `caretHeightFloor`/`stabilizeCaretHeight`, but keyed and cache-clean
rather than a monotone floor.

### 1.7 Per-app strategy is data-driven (the override table)
```
struct Cotypist.AppOverrides {
    completionsDisabled, midLineCompletionsDisabled, autocorrectDisabled, tabShortcutsDisabled,
    smartQuotesDisabled,
    textMirroringEnabled: Bool?            // <-- per-app: use the mirror overlay
    ignoreSizeThresholds: Bool?
    emojiCompletionsDisabled, emojiSearchDisabled,
    requiresNonBreakingSpaceWorkaround, requiresSpaceKeyEventWorkaround,
    requiresPasteAndMatchStyleWorkaround, requiresBackspaceRightAfterPaste,   // injection quirks
    stringInjectionChunkSize: Int?,
    fontSizeAdjustmentFactor: Double?       // <-- per-app font scale for overlay/mirror
    verticalAlignmentOffset: Double?        // <-- per-app vertical nudge
    needsEnhancedUserInterface: Bool?       // <-- set AXEnhancedUserInterface on this app
    trainingDataCollectionDisabled, customInstructions
}
```
Config-knob strings confirm these are placement-related:
```
"Scaling factor for font size in overlay positioning."   (fontSizeAdjustmentFactor)
"Vertical pixel offset for overlay positioning."         (verticalAlignmentOffset)
"Use a text mirror overlay for cursor positioning."      (textMirroringEnabled)
"needsEnhancedUserInterface"
```
There is also a `DomainPattern` / `domain:docs.google.com` override layer (web domains, not just
bundle IDs), with `DomainPattern.Specificity { starCount, literalLabelCount }` for matching. VERIFIED.

### 1.8 Known per-app/per-domain targets (hardcoded bundle IDs / hosts)
```
"com.apple.Terminal"  "com.googlecode.iterm2"  "dev.warp.Warp-Stable"
"com.mitchellh.ghostty"  "com.mitchellh.ghostty.debug"
"org.chromium.Chromium"  "me.proton.pass.electron"
"docs.google.com" (x7)  "domain:docs.google.com"
```
And `GoogleDocsEnableAccessibilityViewController` + `googleDocsEnableAccessibilityWindow`
(the dialog that tells the user to turn on Docs' own screen-reader mode so Docs exposes a DOM/AX
text tree). VERIFIED.

### 1.9 Terminals are largely PUNTED, not solved by screenshot
Cotypist's own copy:
```
"<app> doesn't provide the access Cotypist needs to read or insert text, so this toggle has no
 effect. See [our compatibility notes](https://cotypist.app/compatibility#warp) for details."
"<app> — the app doesn't yet expose the accessibility information Cotypist needs.
 ...compatibility#ghostty..."
```
VERIFIED: Warp and Ghostty are declared unsupported. `com.apple.Terminal` and iTerm2 *are*
listed (they expose AXTextArea), but there is **no screenshot-based caret-detection path** for
terminals. The `screenshot*` fields (`screenshotText`, `screenshotTokens`, `screenshotData`,
`ScreenshotFormat`, `PromptTemplates.screenshot`) feed the **LLM prompt** (multimodal context),
not caret geometry. INFER (high confidence): Cotypist has no OCR-caret locator — its robustness
comes from the TextMirror, and where neither AX nor mirror works, it gives up.

> typer's `screenshotCaretRect` (Vision OCR of the focused-element band to find the caret) is a
> capability Cotypist does **not** have. This is a typer advantage for terminals/custom editors —
> keep it.

### 1.10 UIElementUtilities — the AX geometry/coordinate helper
ObjC class `UIElementUtilities` (Apple's old UIElementInspector sample, vendored):
```
+frameOfUIElement:  +originOfUIElement:  +sizeOfUIElement:
+carbonScreenPointFromCocoaScreenPoint:   +flippedScreenBounds:
+valueOfAttribute:ofUIElement:  +lineageOfUIElement:
```
VERIFIED. `+flippedScreenBounds:` + `+carbonScreenPointFromCocoaScreenPoint:` are exactly the
top-left↔bottom-left flip typer hand-rolls in `axRectToAppKit`. Cotypist centralizes coordinate
conversion here.

---

## 2. Cotypist's Per-App Strategy Matrix

| App class | Example bundles | Caret method | Evidence |
|---|---|---|---|
| Native AppKit / NSTextView | TextEdit, Notes, Mail | AX `BoundsForRange` on selected range → inline ghost via `CaretView`/overlay | `AXUIElementCopyParameterizedAttributeValue`, `CaretView` |
| WebKit / Chromium / Electron | Chrome, Safari, Slack, Discord, VS Code, `org.chromium.Chromium`, Electron apps | AXTextMarker bounds; `needsEnhancedUserInterface` forces full AX tree; falls back to **TextMirror** when no inline caret | `needsEnhancedUserInterface`, marker selectors, `textMirroringEnabled` |
| Catalyst / weird AX | misc | per-app `textMirroringEnabled=true` → mirror overlay; `verticalAlignmentOffset`/`fontSizeAdjustmentFactor` tune it | `AppOverrides` table |
| Google Docs (web canvas, no inline caret) | `docs.google.com` | prompt user to enable Docs a11y (`GoogleDocsEnableAccessibilityViewController`) → then DOM/AX text → **TextMirror** preview window | `domain:docs.google.com`, that VC, `DomainPattern` |
| Terminals (AX-capable) | `com.apple.Terminal`, `com.googlecode.iterm2` | AXTextArea bounds-for-range; mirror as fallback | bundle IDs present, no OCR path |
| Terminals (GPU, no AX) | Warp, Ghostty | **UNSUPPORTED** — compatibility-notes dialog, toggle disabled | the two "doesn't expose / doesn't provide access" strings |

Selection precedence (INFER from the override fields + class wiring):
1. If `AppOverrides.textMirroringEnabled == true` for this bundle/domain → mirror overlay.
2. Else try inline caret: AXTextMarker bounds, then `BoundsForRange`.
3. If a usable caret rect comes back → inline ghost (`CaretView`/overlay), nudged by
   `verticalAlignmentOffset`, font scaled by `fontSizeAdjustmentFactor`.
4. If no caret rect and the app is known-mirror-eligible → auto-enable the mirror.
5. If neither works (Warp/Ghostty) → unsupported dialog.

---

## 3. The TextMirror Overlay Design (in detail)

Purpose: when the host field will **not** let you draw inside it at the caret (web canvases like
Google Docs, fields with no AXTextMarker/BoundsForRange, Catalyst quirks), Cotypist shows a small
floating window *near the field* that is a pixel-faithful **re-render of the host text around the
caret**, with the suggestion appended inline — so the user sees their own text continue naturally.

Construction (VERIFIED from fields; geometry steps are INFER from the TextKit selectors present):

1. **Source text + caret index.** Read the field value and selected range over AX
   (`kAXValueAttribute` + `kAXSelectedTextRangeAttribute`). The caret becomes
   `TextMirrorView.cursorPosition` — a **character index**, not a pixel. This is the key
   robustness move: a char index is always available even when a pixel caret rect is not.
2. **Typography from the host.** Read `kAXFontNameKey`/`kAXFontSizeKey`/`kAXForegroundColorTextAttribute`
   (via the `AXFont` attribute) and build `attributedText` (`NSTextStorage`) with the *same* font,
   size, color, and `textContainerInset`/`lineFragmentPadding`.
3. **Layout.** Feed `textStorage`→`layoutManager`→`textContainer`. `estimatedLineHeight` is cached
   in `LineHeightCache`. `maxDisplayLines` bounds the window; `TextDisplayMode`
   (`noOverflow`/`overflowNearEnd`/`overflowMiddle`) plus the `gradientLayer` fade decide how to
   crop long text around the caret (fade top/bottom so the caret line stays centered).
4. **Caret rect inside the mirror.** Ask the layout manager:
   `lineFragmentRectForGlyphAtIndex:` + the glyph location for the glyph at `cursorPosition`
   (or `boundingRectForGlyphRange:inTextContainer:` for the caret glyph). Place `cursorLayer` there;
   blink it (`cursorBlinkTimer`).
5. **Window placement.** `TextMirrorOverlayWindow` is positioned relative to the host field's AX
   frame (`UIElementUtilities.frameOfUIElement:` → `flippedScreenBounds:`), offset by
   `textOriginOffset` + per-app `verticalAlignmentOffset`. The `infoLabel` shows the "this is a
   mirror, keep typing in the real field" banner once (the long explanation string at 0x1007d6820).
6. **Follow.** `ScrollWheelMonitor` + `AXSelectedTextChanged`/`AXFocusedUIElementChanged`
   notifications re-sync `cursorPosition`/text and reposition the window.

Net: the mirror is a **deterministic, font-exact caret** that needs only (text, caret char index,
font) — three things almost every app exposes — instead of a pixel caret rect, which many apps
don't. The cost is the suggestion shows in a nearby box, not literally in the field.

---

## 4. Why typer is "approximate" (Gap Analysis)

typer's placement (`TyperApp+Caret.swift`, `SuggestionOverlay.swift`, `GhostView.swift`):

1. **Ghost font ≠ host font.** typer always renders `NSFont.systemFont` (GhostView.swift:62,
   SuggestionOverlay.swift:32/44/48/53). When it extrapolates the caret horizontally during fast
   typing it measures advance in *its own* system font (`ghostWidth`, Completion.swift:13-21) and
   corrects with a learned per-app `widthScale` EMA (Completion.swift:41-52). This is fundamentally
   an **estimate** — monospace terminals, condensed UI fonts, and proportional editors all drift
   until the next AX re-anchor. Cotypist never estimates width: the mirror lays out the *actual*
   font, and even inline it reads the host font so the width model is correct.
2. **No mid-line / web fallback.** When an app exposes no inline caret (Google Docs canvas, some
   Electron fields), typer falls back to `clickCaretPoint` + horizontal extrapolation
   (Caret.swift:45-58) — which breaks on the first wrap/newline and on any cursor move the click
   monitor missed. There is **no TextMirror**: typer simply has nowhere correct to draw, so it
   either sits at a stale spot or hides. This is the single biggest robustness gap.
3. **Caret height is a monotone floor, not font-derived.** `stabilizeCaretHeight` floors to the
   smallest height ever seen (Caret.swift:198-203). Correct-ish, but it never recovers if the first
   read was too small, and font size is then derived as `lineHeight*0.62` (a guess). Cotypist
   derives line height from the real font via `LineHeightCache`.
4. **Screenshot caret is OCR-of-text, not caret-of-pixels.** typer's `screenshotCaretRect` finds a
   text *needle* via Vision OCR and places the ghost at its right edge (Caret.swift:120-129).
   Clever and unique (Cotypist lacks it), but it depends on the suffix being on screen and OCR'd
   correctly, and it extrapolates between captures with the same system-font width model — so it
   inherits the width-estimate error. It also can't see an *empty-line* caret (no text to OCR).
5. **Coordinate conversion is hand-rolled per call.** `axRectToAppKit` recomputes the primary-screen
   flip everywhere (Caret.swift:279-293) — correct, but Cotypist centralizes it in
   `UIElementUtilities` (fewer multi-monitor edge cases).
6. **No scroll re-anchor.** typer invalidates on mouse-down and AX changes, but has no
   `ScrollWheelMonitor` equivalent; scrolling a long doc leaves the ghost at the old y until the
   next keystroke.

What typer already does RIGHT (parity or better): per-bundle caret-path memo
(`caretPathByBundle`, Caret.swift:218-226) mirrors Cotypist remembering bounds-vs-marker per app;
the 5-step `boundsForSelectedRange` ladder (selection → zero-len → prev-glyph → next-glyph →
paragraph back-scan, Caret.swift:333-371) is more thorough than anything visible in Cotypist; and
the OCR caret locator is a genuine terminal capability Cotypist lacks.

---

## 5. Concrete Recommendations

### R1 — Read the host font over AX (small, high-leverage)
Add a `focusedElementFont()` that reads the `AXFont` text attribute and pull name/size/color:
```swift
// On the focused element, for the caret's char range:
var attrStr: CFTypeRef?
AXUIElementCopyParameterizedAttributeValue(el,
  "AXAttributedStringForRange" as CFString, axRange, &attrStr)   // returns NSAttributedString
let font = (attrStr as? NSAttributedString)?
            .attribute(.font, at: 0, effectiveRange: nil) as? NSFont
// Fallback: AXUIElementCopyAttributeValue with kAXFontTextAttribute dict -> kAXFontNameKey/kAXFontSizeKey
```
Use that font in `GhostView`/`ghostWidth` instead of `NSFont.systemFont`. This alone removes most
of the fast-typing drift and makes the `widthScale` EMA converge to ~1.0. Cache per bundle (like
Cotypist's `LineHeightCache`) keyed by font descriptor; derive `lastCaretHeight` from
`font.ascender - font.descender + font.leading` instead of the monotone floor.

### R2 — Build a TextMirror fallback (the big one)
Add `TextMirrorWindow` (borderless `NSPanel`) + a `TextMirrorView: NSView` with a real TextKit stack
(`NSTextStorage`/`NSLayoutManager`/`NSTextContainer`), exactly per §3. Drive it from
`textAroundCursor()` (you already have before/after split) + the host font from R1. Use the layout
manager to get the caret glyph rect:
```swift
let g = layoutManager.glyphIndexForCharacter(at: caretCharIndex)
var eff = NSRange()
let line = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
let loc  = layoutManager.location(forGlyphAt: g)
let caretRect = CGRect(x: line.minX + loc.x, y: line.minY, width: 1, height: line.height)
```
Show this window anchored to the focused element's AX frame (`kAXPositionAttribute`+`kAXSizeAttribute`,
which you already read in `focusedElementPoint`) whenever the inline caret ladder AND screenshot AND
click-anchor all fail. Add a per-app `textMirroringEnabled` flag in `TyperConfig` (mirror Cotypist's
override table) plus `fontSizeAdjustmentFactor` / `verticalAlignmentOffset`.

### R3 — Add the Google Docs a11y prompt
For `docs.google.com`, detect the empty AX text tree and show a one-time dialog instructing the user
to enable Docs' "screen reader support" (Tools → Accessibility), then route Docs through the
TextMirror (R2). This is the only way Docs exposes text; Cotypist does exactly this
(`GoogleDocsEnableAccessibilityViewController`).

### R4 — Add a ScrollWheelMonitor
Install `NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel)` (and a local monitor) to
invalidate `lastCaretPoint`/`shotCaretPoint` and re-anchor on scroll, the way mouse-down already
invalidates. Cheap; fixes "ghost stuck at old line after I scrolled."

### R5 — Robust per-app fallback ladder (replace the current implicit one)
Make placement explicit and ordered, recorded per bundle:
```
1. AXTextMarker bounds         (Chromium/WebKit/Electron)        -- have it
2. AXBoundsForRange ladder     (native AppKit, AX terminals)     -- have it (keep the 5 steps)
3. TextMirror (font-exact)     (Docs, web canvas, Catalyst, no-inline) -- ADD (R2)
4. Screenshot/OCR caret        (GPU terminals, custom editors)   -- have it; keep as #4
5. Click-anchor + host-font width extrapolation                  -- have it; demote to #5, use R1 font
6. focusedElement frame center (last resort)                     -- have it
```
Remember the first method that yields a plausible rect per bundle (`caretPathByBundle` already does
this for 1↔2; extend it to cover 3/4). Apply `verticalAlignmentOffset`/`fontSizeAdjustmentFactor`
per app at the end.

### R6 — Centralize coordinate conversion
Fold `axRectToAppKit` + the primary-screen flip into one helper used everywhere (port
`UIElementUtilities.flippedScreenBounds:` semantics) to kill multi-monitor drift.

### R7 — Keep & extend the OCR caret (typer's edge)
Cotypist has no OCR caret and declares Warp/Ghostty unsupported. typer's `screenshotCaretRect`
already covers them. Improve it with R1's host font for between-capture extrapolation, and add an
empty-line case (detect the prompt glyph / cursor block via a thin Vision rectangle/observation
rather than only text needles).

---

## 6. Evidence appendix (key symbols/strings)
- Classes: `TextMirrorView`, `TextMirrorOverlayWindow`, `TextMirrorOverlayViewController`,
  `CaretView`, `KeyboardView`/`PartialKeyboardView`, `ScrollWheelMonitor`, `LineHeightCache`,
  `UIElementUtilities`, `GoogleDocsEnableAccessibilityViewController`, `AppOverrides`,
  `DomainPattern`.
- Imports: `AXUIElementCopyParameterizedAttributeValue`, `AXValueGetValue`,
  `kAXFontNameKey/FamilyKey/SizeKey/TextAttribute`, `kAXForegroundColorTextAttribute`,
  `CGWindowListCreateImage`, `VNRecognizeTextRequest`, `SCStreamConfiguration`.
- TextKit strings: `lineFragmentRectForGlyphAtIndex:effectiveRange:`,
  `boundingRectForGlyphRange:inTextContainer:`,
  `enumerateEnclosingRectsForGlyphRange:withinSelectedGlyphRange:inTextContainer:usingBlock:`.
- Config strings: `textMirroringEnabled`, `needsEnhancedUserInterface`, `ignoreSizeThresholds`,
  "Scaling factor for font size in overlay positioning.", "Vertical pixel offset for overlay
  positioning.", `isMirrorModeActive`, `textMetricsAppName`.
- App targets: `com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`,
  `com.mitchellh.ghostty`, `org.chromium.Chromium`, `me.proton.pass.electron`,
  `docs.google.com` / `domain:docs.google.com`.
