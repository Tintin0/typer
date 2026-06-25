# typer Overhaul — Authoritative Implementation Spec

Status: ready for the implementation fleet. Derived from the six reverse-engineering docs in
`docs/research/` (context-capture, caret-placement, stability, feature-mechanics, swift-techniques,
typer-map). Every file/line anchor in this spec was re-verified against `scripts/typer/*.swift` at
authoring time; treat line numbers as anchors, re-grep before editing.

**Build/verify command (run after every change, gate each wave on it):**
```
bash /Users/jason/Code/typer/scripts/build.sh
```
Pure compile-only check (no install/restart): `swiftc -O scripts/typer/*.swift -o /tmp/typer-check`
(plus, if you touched the helper, `clang++` builds `scripts/llama_server.cpp` — see build.sh).

Architecture reminder: one `swiftc` module of all `scripts/typer/*.swift` + a C++ `llama_server.cpp`
helper over a pipe. New `.swift` files just need to land in `scripts/typer/`. Config is a flat
`TyperConfig` struct + hand-rolled TOML `load()` switch; persistence is per-key line rewrite via
`writeConfig` (TyperApp+Menu.swift:179). Menu is a SwiftUI popover (`MenuPopover.swift`) driven by
`MenuSnapshot`; Bool toggles route through `setToggle`.

---

## A. THE WAVE PLAN (compact)

Waves are ordered so no two parallel agents edit the same Swift file. Each wave must compile (build
command above) before the next starts. Wave 0 is a single agent; later waves fan out.

| Wave | Agents (parallel) | Owns | Depends on |
|---|---|---|---|
| **0 — Foundation** | 1 agent | ALL new `TyperConfig` fields (struct + load() + config.example.toml) for every feature below; `AppOverrides.swift` (new) struct + JSON store; `SettingsWindow.swift` (new) shell + shared `SliderRow`/`StepperRow`/`SegmentedRow` SwiftUI components; `setInt`/`setDouble`/`setString` sibling setters in TyperApp+Menu.swift; new `MenuAction` cases (stubs) | — |
| **1A — Caret core** | 1 agent | `TyperApp+Caret.swift`, new `TextMirror.swift`, new `CoordinateUtil.swift`, new `ScrollMonitor.swift` | W0 |
| **1B — Capture/stability core** | 1 agent | `TyperApp+Context.swift`, `TyperApp+AXObserver.swift`, new `AXSafe.swift`, new `Admissibility.swift` | W0 |
| **1C — Stability/denylist** | 1 agent | `TyperApp.swift` (denylist + secure-role + isAppDisabled), `TyperApp+EventTap.swift` (secure gate only) | W0 |
| **2A — Settings-resident features** | 1 agent | `SettingsWindow.swift` content for snooze(#3)/length(#9)/personalization(#10)/per-app-instr(#1) controls; `TyperApp+Menu.swift` snooze state + countdown | W0, W1C (snooze guard) |
| **2B — Completion semantics** | 1 agent | `TyperApp+Completion.swift` generate() guards (snooze/denylist hooks land here), mid-line fidelity(#13); `llama_server.cpp` FIM | W1B, W1C |
| **2C — Model + updates + move** | 1 agent | `ModelRouter.swift`, `ModelDownloader.swift`, `TyperApp+Model.swift` (#11); `build.sh`/Info.plist + Sparkle(#6); LetsMove(#12) in TyperApp.swift launch | W0 |
| **2D — Inline-pred + emoji + typo** | 1 agent | inline-prediction(#4) onboarding; emoji(#7) in TyperApp+Typo.swift; typo styling/gate(#8) in TyperApp+Typo.swift + SuggestionOverlay/GhostView | W0 |
| **3 — Multi-candidate picker** | 1 agent | `LlamaClient.swift`, `HelperProtocol.swift`, `llama_server.cpp`, `SuggestionOverlay.swift`, `GhostView.swift`, `TyperApp+EventTap.swift` accept keys | W2B (FIM landed), W2D (overlay styling landed) |
| **4 — MLOps wiring** | 1 agent | `TrainingLog.swift`, `ModelRouter.swift` (feedback signal), training pipeline glue | W3 |

Conflict notes baked into the waves:
- `TyperApp+Completion.swift` is touched by #2/#3/#9/#10/#13 → all routed through **one** owner (W2B);
  W0 pre-adds the config reads so W2B only edits `generate()` prologue once.
- `TyperApp+Menu.swift` + `MenuPopover.swift` + the new `SettingsWindow.swift` are the menu cluster →
  W0 builds the shell + shared components, W2A fills content. No other wave edits them.
- `build.sh`/Info.plist touched by #6/#11/#12 → all in **W2C** (one agent, one Info.plist edit block).
- Caret/context cluster (#13/#14) split: caret in W1A, context in W1B; #14 Google Docs is a thin branch
  added by W1A (caret) + W1B (context) since both already own those files.

RISK GATES (confirm before W3/W4): multi-candidate picker (#3) is the deepest blast radius (helper
protocol + C++ + overlay + keymap). MLOps (#4) changes the training signal. See section H.

---

## B. BIG-GRIPE #1 — ROBUST CARET PLACEMENT (Wave 1A) [IN DEPTH]

Goal: ghost text lands on the real caret across native AppKit, WebKit/Electron, Catalyst, terminals,
and Google Docs — and stops drifting during fast typing. Cotypist's robustness comes from (1) reading
the **host font** over AX and (2) a deterministic **TextMirror** (TextKit re-render → caret glyph
rect) for AX-hostile fields. typer keeps its OCR caret edge (Cotypist lacks it) and adds these.

### B.1 Explicit fallback ladder (replace the implicit one)
Make placement an ordered, per-bundle-memoized ladder in `TyperApp+Caret.swift` (current logic:
`caretPoint` 205-233, `textMarkerCaretRect`, `boundsForSelectedRange` 5-step ladder 307-372,
screenshot caret 98-135, click-anchor 45-58, `axRectToAppKit` 279-293, `caretPathByBundle`
TyperApp.swift:47).

```
1. AXTextMarker bounds        (Chromium/WebKit/Electron)         — exists, keep
2. AXBoundsForRange ladder    (native AppKit, AX terminals)      — exists, keep the 5 steps
3. TextMirror (font-exact)    (Docs, web canvas, Catalyst, no-inline) — ADD (B.3)
4. Screenshot/OCR caret       (GPU terminals, custom editors)    — exists, keep as #4
5. Click-anchor + host-font width extrapolation                 — exists, demote to #5, use host font (B.2)
6. focusedElement frame center (last resort)                    — exists, keep
```
Extend `caretPathByBundle` to record which of {1,2,3,4} succeeded per bundle id (it currently memoizes
1↔2). After a rect is chosen, apply per-app `verticalAlignmentOffset` + `fontSizeAdjustmentFactor`
from `AppOverrides` (W0).

API to add:
```swift
enum CaretPath { case marker, bounds, mirror, ocr, click, frame }   // extend existing
func caretRect(for el: AXUIElement, bundle: String) -> (rect: CGRect, path: CaretPath)?
```

### B.2 Read the host font over AX (small, high-leverage) — kills fast-typing drift
typer always renders `NSFont.systemFont` (GhostView.swift:62, SuggestionOverlay.swift:32/44/48/53) and
extrapolates caret-x with a learned per-app `widthScale` EMA — an estimate that drifts on
monospace/condensed/proportional fonts. Read the real font:

```swift
// On the focused element, for the caret char range:
func focusedElementFont(_ el: AXUIElement, at loc: Int) -> (font: NSFont, color: NSColor?)? {
    var range = CFRange(location: max(0, loc), length: 1)
    guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
    var attrRef: CFTypeRef?
    AXUIElementCopyParameterizedAttributeValue(
        el, "AXAttributedStringForRange" as CFString, axRange, &attrRef)
    if let s = attrRef as? NSAttributedString, s.length > 0 {
        let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let c = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        if let f { return (f, c) }
    }
    // Fallback: kAXFontTextAttribute dict -> kAXFontNameKey/kAXFontSizeKey
    return nil
}
```
- Use this font in `GhostView`/`ghostWidth` instead of `NSFont.systemFont`. The `widthScale` EMA then
  converges to ~1.0 (keep it as a residual corrector, don't delete).
- Derive caret height from `font.ascender - font.descender + font.leading` instead of the monotone
  `stabilizeCaretHeight` floor (Caret.swift:198-203) when a font is available; keep the floor as fallback.
- Cache per bundle keyed by font descriptor (a `LineHeightCache`-style `Locked<[String: NSFont]>`).
- Wrap the AX read with the 50 ms messaging timeout from B.1/D (AXSafe).

### B.3 TextMirror fallback (the big one)
New file `TextMirror.swift`: a borderless `NSPanel` + an `NSView` with a real TextKit stack that
re-renders host text around the caret and asks the layout manager for the **exact caret glyph rect**.
Needs only (text, caret char index, font) — three things almost every app exposes — instead of a pixel
caret rect many apps don't.

```swift
final class TextMirrorView: NSView {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer()
    var cursorPosition = 0                 // caret as CHARACTER INDEX, not pixel
    private let caretLayer = CALayer()
    init() { super.init(...); textStorage.addLayoutManager(layoutManager)
             layoutManager.addTextContainer(textContainer)
             textContainer.lineFragmentPadding = 0 }
    func update(text: String, caret: Int, font: NSFont, color: NSColor, inset: NSSize) {
        let attr = NSMutableAttributedString(string: text,
            attributes: [.font: font, .foregroundColor: color])
        textStorage.setAttributedString(attr)
        cursorPosition = caret
        textContainer.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
    }
    func caretRectInMirror() -> CGRect {
        let g = layoutManager.glyphIndexForCharacter(at: cursorPosition)
        var eff = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
        let loc  = layoutManager.location(forGlyphAt: g)
        return CGRect(x: line.minX + loc.x, y: line.minY, width: 1, height: line.height)
    }
}
```
Window placement: anchor `TextMirrorWindow` to the focused element's AX frame
(`kAXPositionAttribute`+`kAXSizeAttribute`, already read in `focusedElementPoint`), offset by per-app
`verticalAlignmentOffset`. Drive `text`/`caret` from the existing before/after split
(`textAroundCursor`, Context.swift:155-181) + host font from B.2. Show only when ladder steps 1,2,4,5
all fail OR `AppOverrides.textMirroringEnabled == true` for the bundle/domain. Add a one-time info
banner ("keep typing in the real field").

Acceptance (B): in TextEdit/Notes/Mail the inline ghost sits on the caret with no horizontal drift at
120+ wpm; in a `textMirroringEnabled` app the mirror window shows the suggestion at the correct glyph;
ghost font visually matches host font in a monospace editor and a proportional one; build passes.

### B.4 ScrollWheelMonitor (#14 support, cheap)
New `ScrollMonitor.swift`: `NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel)` + a local
monitor that invalidates `lastCaretPoint`/`shotCaretPoint` and re-anchors, mirroring how mouse-down
already invalidates. Fixes "ghost stuck on old line after I scrolled."

### B.5 Google Docs flow (#14)
For `docs.google.com` (detect via window title/URL over AX): if the AX text tree is empty, show a
one-time dialog instructing the user to enable Docs' "screen reader support" (Tools → Accessibility,
Cmd-Opt-Z), then route Docs through TextMirror (B.3). This is the only way Docs exposes text. Branch
lives in `caretRect`/`textAroundCursor`.

### B.6 Centralize coordinate conversion
New `CoordinateUtil.swift`: fold `axRectToAppKit` + the primary-screen flip (Caret.swift:279-293) into
one helper (port `UIElementUtilities.flippedScreenBounds:` semantics) used everywhere. **AX rects are
in points — never divide by `backingScaleFactor`** (that's only for SCK/Vision pixel math). The
existing off-main snapshot of `primaryMaxY` on the main thread is correct — preserve it.

---

## C. BIG-GRIPE #2 — EFFICIENT & STABLE SCREEN/CONTEXT CAPTURE (Wave 1B) [IN DEPTH]

typer already does SCK single-frame `sourceRect` band-clip + downscale for the **caret locator**
(good). The gaps: **context OCR still grabs the full window @0.5×**; capture is timer-driven (4 s);
no per-app backoff; char-count truncation instead of token-space budgeting. Cotypist crops OCR to the
field column, is AX-event driven, and budgets per-source in token space.

### C.1 Crop context OCR to a caret-anchored band + X-range filter (highest ROI)
In `TyperApp+Context.swift` `screenOCR` path, stop capturing the whole window. Reuse the machinery
already in `screenshotCaretRect`:
```swift
let field = focusedElementQuartzRect()                       // already computed for caret
let clip  = field.insetBy(dx: 0, dy: -field.height * 6)       // ~6 lines above
                .intersection(windowFrame)
let img = captureFocusedWindow(clip: clip, scale: 0.5)        // existing SCK sub-rect path
// Then filter Vision observations to the field's normalized X-range (port performOCR(on:textFieldXRange:)):
let xLo = (field.minX - clip.minX) / clip.width
let xHi = (field.maxX - clip.minX) / clip.width
let kept = observations.filter { let m = $0.boundingBox.midX; return m >= xLo - 0.1 && m <= xHi + 0.1 }
```
Expected ~5–10× less Vision work and removal of sidebar/toolbar noise. Keep the existing `.accurate`
(context) vs `.fast` (caret) profiles, `minimumTextHeight`, confidence gate, `isLikelyText`. Add
`req.recognitionLanguages = ["en-US"]` when the user is monolingual.

### C.2 Event-driven extra-context capture (not the 4 s timer)
typer already observes `kAXSelectedTextChangedNotification` (AXObserver.swift). Instead of refreshing
background context on a fixed 4 s tick, set `backgroundDirty = true` on that notification and run the
throttled refresh on a ~600 ms debounce after the last change (Cotypist's `lastRefreshCheck` gate
pattern). Keep a low-frequency safety timer for AX-silent apps (the current path). Never capture on the
synchronous keystroke path.

### C.3 Cheap AX field metadata into the prompt (free signal)
Add to the AX read (no screenshot): `kAXPlaceholderValueAttribute`, `kAXTitleAttribute`,
`kAXHelpAttribute`, `kAXDescriptionAttribute`; for web fields `"AXDOMIdentifier"`/`"AXDOMClassList"`;
page URL via window `"AXURL"`/`AXWebArea`. Surface as a labeled block in
`assembledContext(immediate:)` (Context.swift:336) before `blocks.append(immediate)`:
`Field: <placeholder|title> in <app> — <url>`. Mirrors `PromptCoordinator.Context.TextFieldProperties`.

### C.4 Token-space budgeting + tokenization cache (LlamaClient)
Replace char `suffix()` truncation with token-space budgeting. Add to `LlamaClient.swift`:
```swift
struct TokCacheKey: Hashable { let string: String; let addBOS: Bool; let allowSpecial: Bool }
final class TokenizationCache {            // LRU by lastUsed
    private var cache: [TokCacheKey: (tokens: [Int32], lastUsed: Date)] = [:]
}
```
Tokenize each block (immediate, field-meta, style, background/OCR, topic) independently via the
helper's tokenizer; fill a priority budget (immediate → field-meta → style → background) so a long
background block can't crowd out the live line; keep the unchanging prefix stable for llama.cpp KV
reuse. Cache `correctionPromptCache`-style the autocorrect prefix too.
(If the helper has no standalone tokenize endpoint, add one to `llama_server.cpp`; coordinate with
W2B which also owns the helper — W1B adds the endpoint, W2B consumes FIM.)

### C.5 Per-app admissibility backoff (stability)
New `Admissibility.swift` (shared with C/D). Add `inadmissibleUntil: [String: Date]` (auto-expiring)
and `pollingSuspendedForPID: Set<pid_t>` (clears on relaunch). When `captureFocusedWindow`/AX walk
returns empty or errors for an app, set exponential backoff (up to ~60 s) keyed by bundle id; skip
capture while backed off. Mirrors `applicationsTemporarilyInadmissibleForAutomaticCompletion` +
`pollingTemporarilySuspendedForPID`.

Acceptance (C): context OCR captures only the caret band (verify via a temporary debug rect dump);
background refresh fires on typing, not on a clock, in an AX-active app; an app that errors on AX is
skipped for the backoff window; field placeholder/URL appears in the assembled prompt; build passes.

---

## D. STABILITY HARDENING (Waves 1B + 1C)

### D.1 Bound every AX call (highest impact) — `AXSafe.swift` (W1B)
typer has **zero** `AXUIElementSetMessagingTimeout` calls; a hung host (Electron/IDE) can stall the
main thread → the "freezes in app X" gripe. On creating any app/system-wide `AXUIElement` used for
reads (`TyperApp+Caret.swift`, `TyperApp+Context.swift`, `updateAXObserver()`):
```swift
AXUIElementSetMessagingTimeout(element, 0.05)   // 50 ms, Cotypist-style
```
Treat `kAXErrorCannotComplete` as "skip this tick," never block. Provide a tiny wrapper:
```swift
@inline(__always) func axRead(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}
```

### D.2 Deferred-release AXObserver + stop removing per-element notifications (W1B)
`TyperApp+AXObserver.swift`: `refreshObservedElement()` currently calls `AXObserverRemoveNotification`
on the previously focused element (lines 57-58) — on a focus change that element may be dead (crash/hang
vector Cotypist deliberately avoids: it imports neither `AXObserverRemoveNotification` nor
`AXObserverInvalidate`). `teardownAXObserver()` (67) releases the observer synchronously.

Fix: wrap the observer so teardown removes the run-loop source now, then releases the observer off the
callback stack; and on focus change, tear down + recreate (deferred release) instead of removing
per-element notifications on possibly-dead elements.
```swift
final class DeferredAXObserver {
    private(set) var value: AXObserver?
    func set(_ new: AXObserver?) {
        let old = value; value = new
        if let old { DispatchQueue.main.async { _ = old } }   // release after callback frame unwinds
    }
}
```
Keep typer's strengths: listen-only tap, accept-tap-only-while-showing, idempotent `tapEnable`,
`syntheticMarker` tagging, pasteboard snapshot/restore, `PowerState` throttling. Do not regress these.

### D.3 Secure-field role check + password-manager denylist (W1C)
typer guards only on `IsSecureEventInputEnabled()` (EventTap.swift:146, Completion.swift:90) — misses
non-secure-input password fields and secure web fields, and has no PM denylist for the **completion**
path (only training capture uses `TrainingLog.sensitiveAppBundles`).

Add to `TyperApp.swift`:
```swift
func focusedFieldIsSecure(_ el: AXUIElement) -> Bool {
    if (axRead(el, kAXRoleAttribute as String) as? String) == (kAXSecureTextFieldRole as String) { return true }
    return (axRead(el, kAXSubroleAttribute as String) as? String) == "AXSecureTextField"
}
static let passwordManagerBundles: Set<String> = [
  "com.1password.1password","com.agilebits.onepassword","com.apple.Passwords",
  "com.lastpass.LastPass","com.lastpass.lastpassmacdesktop",
  "com.dashlane.Dashlane","com.dashlane.dashlanephonefinal",
  "com.bitwarden.desktop","com.keepersecurity.passwordmanager","com.callpod.keepermac.lite",
  "com.sibersystems.RoboFormMac","com.nordsec.nordpass","in.sinew.Enpass-Desktop",
  "me.proton.pass.electron","com.ascendo.DataVaultMac","com.mseven.msecuremac",
  "com.symantec.NortonPasswordManager.combined","org.keepassx.keepassx",
  "org.keepassxc.keepassxc","com.selznick.PasswordWallet",
  "com.outercorner.Secrets","com.outercorner.Secrets-setapp"
]
```
OR `passwordManagerBundles` into `isAppDisabled()` (TyperApp.swift:253) — the single chokepoint
`generate()` already calls — and gate `generate()`/`presentCompletion` on `!focusedFieldIsSecure(...)`.

### D.4 Own-autocomplete suppression default (W1C, user-overridable)
Seed a default-suppressed set (separate from terminals, which typer already handles via
`terminalBundleIDs`): Xcode, VSCode(+Insiders), Cursor `com.todesktop.230313mzl4w4u92`, Windsurf
`com.exafunction.windsurf`, all JetBrains (intellij/pycharm/PhpStorm/CLion/goland/rider/rubymine/
AppCode), Android Studio, Sublime 2/3, MATLAB, RStudio, TablePlus. Make it a Set OR'd into
`isAppDisabled()` but overridable per app via `AppOverrides.completionsDisabled = false`.

### D.5 Per-app quirk overrides table — `AppOverrides.swift` (W0 builds, W1C wires)
All-optional Codable struct keyed by bundle id (and `domain:<pattern>` rows for web), persisted as a
JSON sidecar (`~/Library/Application Support/typer/app_overrides.json`, register in `resetData()`):
```swift
struct AppOverrides: Codable {
    var completionsDisabled, midLineCompletionsDisabled, autocorrectDisabled: Bool?
    var emojiCompletionsDisabled, emojiSearchDisabled: Bool?
    var textMirroringEnabled, needsEnhancedUserInterface, ignoreSizeThresholds: Bool?
    var requiresPasteAndMatchStyleWorkaround, requiresNonBreakingSpaceWorkaround,
        requiresBackspaceRightAfterPaste, requiresSpaceKeyEventWorkaround: Bool?
    var stringInjectionChunkSize: Int?
    var fontSizeAdjustmentFactor, verticalAlignmentOffset: Double?
    var customInstructions: String?
}
```
Resolve = `merge(inCodeDefaults, userAppOverride, userDomainOverride)`, non-nil wins. Expose
`resolvedOverrides` AND `userOverrides` to the settings UI ("inherited vs overridden"). For apps flagged
`needsEnhancedUserInterface`, set `AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface", kCFBooleanTrue)`.

### D.6 Lightweight local hang/crash telemetry (W1C, opt-in, no Sentry)
Main-thread watchdog (`DispatchSourceTimer` pinging a counter the main loop resets; log if it stalls
>N ms) + a signal handler recording the frontmost bundle id at crash time → attributes "flaky in app X."

---

## E. PER-FEATURE SPEC (the remaining planned features)

For each: scope, files, API/data, prompt/menu/UI, acceptance. Caret(#14), capture(#13 mid-line),
stability(#2 denylist, #5? no — #5 is multi-candidate) covered above where noted.

### #1 Per-app custom instructions (W0 config + AppOverrides; W2A UI; W2B prompt)
- Files: `AppOverrides.swift` (`customInstructions`); `TyperApp+Context.swift:assembledContext` (336)
  inject block keyed on `currentAppBundleAndName().bundle`; `SettingsWindow.swift` per-app editor row.
- Prompt: append `globalInstructions + "\n" + perAppInstructions` (per-app last so it can override
  tone), tokenize once, cache as prefix; set a `prefixHasInstructions` flag so the completion code
  invalidates the KV prefix when instructions change.
- Acceptance: setting "be terse" for Slack changes only Slack's completions; build passes.

### #2 Password-manager / secure-field denylist — see D.3/D.4 (W1C).

### #3 Timed snooze (W0 config none-needed; W2A menu + W2B guard)
- Data: `var allCompletionsDisabledUntil: Date?` (global) + `var perAppDisabledUntil: [String:Date]`
  on TyperApp (ephemeral, no persistence). Deadline model, not a timer.
  ```swift
  func completionsAllowed(bundle: String) -> Bool {
      let now = Date()
      if let g = allCompletionsDisabledUntil, g > now { return false }
      if let a = perAppDisabledUntil[bundle], a > now { return false }
      return true
  }
  ```
- Menu: "Snooze for…" submenu (5/15/60 min) + per-app; one 1 Hz `Timer` refreshes status title
  ("⏸ 14m") and clears expired deadlines. Gate in `generate()` (W2B) and `updateStatusTitle()`.
- Acceptance: snooze 5 min suppresses completions and shows countdown; auto-resumes; build passes.

### #4 Disable macOS inline prediction (W2D)
- typer cannot flip another app's `NSTextInputContext`. Detect the global default and guide the user:
  ```swift
  let on = CFPreferencesGetAppBooleanValue(
      "NSAutomaticInlinePredictionEnabled" as CFString, kCFPreferencesAnyApplication, nil)
  ```
- If on, show an onboarding card (`OnboardingWindow.swift`) + menu warning with a "Open Keyboard
  settings" deep-link (`x-apple.systempreferences:com.apple.Keyboard-Settings.extension`). Optionally
  offer one-click write (`CFPreferencesSetValue(..., kCFBooleanFalse, kCFPreferencesAnyApplication,
  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)` + `CFPreferencesAppSynchronize`), recording the
  prior value to restore on uninstall. **RISK:** writing a global default — default to guide-only,
  put the write behind an explicit button (see H).
- Acceptance: when system inline prediction is on, typer surfaces the warning; deep-link opens the pane.

### #5 — (multi-candidate) is Wave 3, see section F.

### #6 Sparkle auto-update (W2C)
- Files: replace home-grown updater in `TyperApp+Menu.swift:269-390`; `build.sh`/Info.plist add
  `SUFeedURL`, `SUPublicEDKey` (Ed25519), `SUEnableAutomaticChecks=true`, `SUScheduledCheckInterval`
  (e.g. 86400); bundle `Sparkle.framework`; point the existing "Check for updates" button at
  `SPUStandardUpdaterController.checkForUpdates(_:)`.
- Keep the git-rebuild path as the source-build fallback (gated on `canUpdate`/`TyperRepoPath`).
- EdDSA flow: `generate_keys` once (private key in Keychain, public into `SUPublicEDKey`); per release
  `sign_update Typer-x.y.z.zip` → paste `edSignature` into a self-hosted `appcast.xml`.
- Acceptance: a stub appcast triggers the Sparkle UI; source builds still self-update via git.

### #7 Emoji completion (W2D)
- Ship 3 public data sets (gemoji-derived), compressed resources decoded once at launch:
  `[String:String]` shortcode→emoji, `Set<String>` modifiable-base, `[String:GenderForms]`.
- Files: `TyperApp+Typo.swift` lookup parallel to `correction(for:)`; `TyperApp+EventTap.swift`
  detect `:name:`/emoticon in `handleTyping`; render via existing span-based `Correction` machinery +
  `SuggestionOverlay.show(correction:)`. Skin-tone/gender from one user pref each (W0 config).
- Two modes: inline expand on a completed `:shortcode:`; `:prefix` search into the candidate overlay.
- Acceptance: typing `:smile:` expands; `:par` offers a filtered list; per-app `emojiCompletionsDisabled`
  respected.

### #8 Suggested-fix styling + typo-suspicion gate (W2D)
- Already substantially built: `SuggestionOverlay.show(correction:)` (39-57) renders red-strike →
  green replacement; suspicion gate exists (`typoMinConfidence`, `rankGuesses`, QWERTY bonus in
  TyperApp+Typo.swift). Two independent settings (W0 config): "Show suggested fixes" and "Suppress
  completion when typo suspected"; flip conservative defaults; polish attributes (named colors
  `autocorrectStrikethroughRed`/`autocorrectCorrectionGreen` equivalents). Detection via
  `NSSpellChecker.shared.checkSpelling(of:startingAt:)` scoped to the current word; cache per word.
- Acceptance: misspelled word shows strike+green fix inline; with the gate on, a misspelled word is
  not extended.

### #9 Completion length control (W0 config exists; W2A UI; W2B consume)
- `cfg.maxCompletionWords` already exists (consumed in `generate()` 361). Add a 5-stop segmented control
  (Short/Medium/Long/Very Long/Ultra Long → word→token caps ~×1.6) in `SettingsWindow.swift` via the
  shared `SegmentedRow` (W0). Setter `setInt`/`setMaxWords` (W0). Stop early on clause boundaries so
  "Long" doesn't pad. Per-app override via `AppOverrides`.
- Acceptance: changing the bucket changes max generated tokens; build passes.

### #10 Personalization strength (W0 config; W2A UI; W2B consume; W4 LoRA)
- New `cfg.personalizationStrength: Double` (0..1) + a `SliderRow` (W0). Interim mechanism: scale style
  sample chars in `assembledContext` (Context.swift:359) and `lexicon.topWords()` count by strength;
  build a `[token:Float]` logit-bias map from high-frequency user words and pass to the sampler
  (`ModelRouter`/helper). Final mechanism (W4): attach a locally-trained LoRA with
  `scale = strengthToScale(level)` (`{off:0, subtle:0.25, light:0.4, standard:0.6, strong:0.8,
  max:1.0}`).
- Acceptance: slider visibly biases toward the user's frequent words at high strength; off = neutral.

### #11 Model catalog + disk-space pre-check (W2C)
- Files: `ModelRouter.swift:downloadTiers` extend with `{repo, quantFile, sizeBytes, runtimeMemBytes,
  isBaseModel, minMemoryGB, recommendedCPUTier}`; `ModelDownloader.swift` add
  `volumeAvailableCapacityForImportantUsage ≥ sizeBytes + margin` pre-check before download;
  `TyperApp+Model.swift:setModelVariant` (51) call it; post-download validate byte size (already
  validates magic+>100MB). Recommendation: `ProcessInfo.physicalMemory` +
  `sysctlbyname("hw.perflevel0.physicalcpu")` → CPUTier → pick largest model fitting RAM/tier.
- Acceptance: low-disk download is blocked with a clear alert; recommended-model notice appears when
  device RAM supports a larger tier.

### #12 Let's Move to /Applications (W2C)
- New routine called once at top of `applicationDidFinishLaunching` (TyperApp.swift:152), before
  onboarding. Detect `Bundle.main.bundleURL` not under `/Applications` (and detect
  `/private/var/folders/.../AppTranslocation/` → always offer); offer to copy via FileManager,
  relaunch via `NSWorkspace.openApplication`, terminate. Vendor LetsMove or the hand-rolled version in
  swift-techniques.md §9. typer builds to `~/Applications`, so this matters mainly for a distributed DMG.
- Acceptance: running from Downloads offers the move; running from /Applications is a no-op.

### #13 Mid-line completion fidelity (W2B) — see also FIM below
- Currently suppressed: `generate()` bails when `isMidLine(after:)` (Completion.swift:344-346).
  Relax to complete at word boundaries mid-line; pass `axCtx.after` to the helper as FIM suffix.
- Acceptance: typing in the middle of a sentence yields a contextually-correct completion that doesn't
  duplicate the trailing text (keep the repeat-drop guard at presentCompletion:434).

### #14 Google Docs AX — see B.5 (W1A caret branch + W1B context branch).

### #15 Privacy/settings pane (W0 shell; W2A content)
- New `SettingsWindow.swift` (model after `OnboardingWindow.swift` controller+SwiftUI-host pattern),
  presented from a new `MenuAction`. Reads/writes the same `cfg` + `writeConfig`. Home for #3/#9/#10/#1
  controls + the shared `SliderRow`/`StepperRow`/`SegmentedRow` components (built once in W0). Privacy
  section surfaces training-capture consent, reset-all-data, and the denylist/override editor.
- Acceptance: a real preferences window opens; all settings round-trip through config.toml/sidecar.

---

## F. WAVE 3 — MULTI-CANDIDATE PICKER (#5) [deepest blast radius]

- Helper (`llama_server.cpp`): emit top-k candidates (small beam or N samples); extend `HelperProtocol.swift`
  wire types (`HelperSuggestion`/`StreamLine`) to carry `[candidate]`.
- `LlamaClient.swift:request` (100-134): parse N candidates.
- `TyperApp`: store `[ActiveCompletion]` + `selectedIndex`.
- `SuggestionOverlay.swift`/`GhostView.swift`: borderless `NSWindow` + `NSTableView` picker anchored
  under the caret (reuse caret anchoring from W1A); top candidate stays the inline ghost.
- `TyperApp+EventTap.swift:accept` (213-245): add a cycle key (Option-Tab / ↑↓) + Return to commit.
- Bound by `maxResultsToShow` (~3–5).
- Acceptance: Option-Tab cycles candidates, Return commits, Tab still accepts word, backtick accepts all;
  the inline ghost = the selected candidate; build passes.

Gated after W2B (FIM) + W2D (overlay styling) so it builds on a stable helper protocol and overlay.

---

## G. MLOps — personalization & feedback into training (Wave 4)

Existing pipeline: `TrainingLog.swift` (`training.jsonl`), KTO recipe, `ModelRouter.swift` (raw vs
distilled race, graded reward, locks at 80% per MEMORY). Base is Qwen3-0.6B; typer-1l is full-FT f16
0.6B. Wire three signals:

1. **Accepted-completion signal (already partly logged).** Ensure `(context, shownCandidates,
   acceptedIndex/acceptedText, rejected)` is logged to `training.jsonl` from `acceptCompletionWord`/
   `acceptCompletionAll` and from multi-candidate selection (W3). This is the KTO positive/negative
   pair source. There is **no "vote" UI** — Cotypist's `userDidVoteForSuggestion` is support-chat, not
   autocomplete feedback. Do not build a vote API; the accept/ignore event IS the signal.
2. **Per-app instructions → prompt, not training.** `customInstructions` shape the prompt prefix only;
   keep them out of the training target so the base model isn't overfit to one app's tone.
3. **Personalization-strength → LoRA scale (W4).** Train a small per-user LoRA from accepted
   completions (KTO pipeline exists); at inference attach with `llama_adapter_lora` and
   `scale = strengthToScale(personalizationStrength)`. Interim: the `[token:Float]` logit-bias map
   from #10. Re-attach on slider change; no base reload.

Model-catalog/tiering changes (#11): add `{sizeBytes, runtimeMemBytes, isBaseModel, minMemoryGB,
recommendedCPUTier}` to the `ModelTier`/catalog in `ModelRouter.swift`; recommend by device RAM/CPU.
Keep shipping base (`-Base`/`-pt`) + instruct variants since typer distills its own (per MEMORY: the
human-grounding tiers were a negative ablation — do not promote grounded tiers; use grounding only for
final personalization).

State to register in `resetData()` (TyperApp+Menu.swift:229): `app_overrides.json`, any per-user LoRA
adapter, the logit-bias map, the inline-prediction "prior value" record.

---

## H. RISKS TO CONFIRM BEFORE IMPLEMENTATION

1. **#4 global default write (`NSAutomaticInlinePredictionEnabled`).** Writing a *global* user default
   on the user's behalf is intrusive and can be unreliable on managed domains. **Recommendation:**
   ship guide-only (detect + deep-link to Keyboard settings) by default; put the one-click write behind
   an explicit, clearly-labeled button that records the prior value for restore. Confirm you want the
   write path at all.
2. **#5 multi-candidate picker** touches the helper protocol, `llama_server.cpp`, overlay, AND keymap —
   highest blast radius and the only feature that changes the wire format. Confirm it should ship in
   this overhaul vs. a follow-up; it is correctly isolated to Wave 3.
3. **#6 Sparkle requires a hosted appcast + a real (notarized for public) signing identity.** typer's
   current stable self-signed cert is fine for self-distribution but Gatekeeper will warn the public
   without notarization. Confirm distribution model (self-hosted unsigned-to-public vs notarized DMG)
   before wiring Sparkle, since it affects `build.sh`.
4. **D.3/D.4 default denylists** suppress completions in password managers (always) and IDEs/own-
   autocomplete apps (overridable). Confirm the IDE list should be on-by-default (it is user-overridable
   per app via `AppOverrides`).
5. **MLOps (#10/#4 LoRA)** is paused per MEMORY (personalization off until re-baselined to Qwen+KTO).
   Confirm whether Wave 4 ships the LoRA path now or only the interim logit-bias map.

---

## I. WEBSITE / MARKETING APPENDIX (brief)

Positioning: **open-source, local-first, on-device autocomplete for macOS** — the credible
privacy-respecting alternative to closed competitors. The open/local promise is the moat; never betray
it. Optional hosted/Pro offerings must be *additive conveniences*, never gates on core local function.

Site sections to add:
- **Hero:** "Autocomplete that never leaves your Mac." One-line: runs llama.cpp + GGUF locally, no
  account, no cloud, source on GitHub. Live ghost-text demo GIF.
- **How it works / Privacy:** the AX + ScreenCaptureKit + Vision stack stays on-device; the
  password-manager denylist + secure-field detection + concealed-clipboard skip as proof points.
- **Models:** the catalog (Qwen3 base/instruct tiers) + "pick by your RAM" tiering; everything
  downloadable, nothing phoned home.
- **Compatibility matrix:** per-app caret support (native/web/terminal/Docs) — turn the fallback ladder
  into a public table (this is exactly what Cotypist does at `/compatibility`, and it builds trust).
- **Open-source / Build from source:** the `build.sh` story; contribution guide.

Optional Pro/PaaS without betraying local-first (all opt-in, all degrade gracefully to fully-local):
- **Hosted appcast + signed/notarized binaries** (Sparkle) — convenience for non-builders; the source
  build is always free.
- **Optional cloud model-distillation service:** users *opt in* to upload (their own) accepted-completion
  logs to train a better personal LoRA in the cloud, downloaded back and run locally. Local KTO remains
  the default; cloud is faster, not required.
- **Pro tier:** per-app custom instructions, multi-candidate picker polish, priority model hosting —
  the same Plus/Pro split Cotypist uses, but with the core completion engine always free and local.
- **Team/SaaS (later):** shared per-app instruction packs / denylists for orgs, managed config — never
  shared *content*, only settings.

Announcement angle: "Cotypist, but open and yours." Lead with privacy + the terminal/OCR caret
capability (a genuine typer advantage Cotypist lacks), and the public compatibility matrix as the
trust signal.

---

## J. BUILD/VERIFY (repeat — gate every wave)
```
bash /Users/jason/Code/typer/scripts/build.sh        # full build + self-sign + restart
swiftc -O scripts/typer/*.swift -o /tmp/typer-check   # compile-only, no install
```
Every wave MUST pass the compile-only check before the next wave starts; the menu/config cluster
(W0→W2A) and the completion-guard cluster (W1C→W2B) are strictly serialized as noted in the wave plan.
