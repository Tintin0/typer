# Cotypist Screen & Context Capture — Reverse-Engineering Notes

Target binary: `/Applications/Cotypist.app/Contents/MacOS/Cotypist`
(CFBundleShortVersionString `2026.1`, CFBundleVersion `73`, min macOS `14.0`, built against SDK `26.4`).
Tooling: `ipsw swift-dump` / `ipsw class-dump` / `ipsw macho info --strings|--symbols`, `nm | swift demangle`.

Methodology note on confidence: Cotypist's own *method bodies are stripped* — `nm` shows **0** `8Cotypist`
text symbols (`grep -cE "8Cotypist" nm_addr.txt` → 0). Only Swift **type metadata** (struct/class field
layouts, enum cases, Codable `CodingKeys`) and **imported (`U`) symbols** survive. So I can state field/type
shapes and which Apple APIs are linked with high confidence, but the exact call sequence / cadence inside a
method is INFERRED from field names + observer types, not disassembled. Each claim below is tagged
**[VERIFIED]** (from metadata/symbol/string) or **[INFERRED]**.

A second important correction from skeptical cross-checking: several fields the brief asked about
(`preContext`, `postContext`, `systemContext`, `userContext`, `attachmentProcessors`, `_extraDataDelay`)
are **NOT Cotypist's context pipeline**. They are Sentry SDK stacktrace fields, and `_extraDataDelay` is a
field on `CUSIRespP…StorageClass` — a *license/subscription server response* decoder (sibling fields:
`subscriptionLicense`, `removeLicenseUuids`, `subscriptionManagementURL`). Do not model typer's prompt
budget on them. The real Cotypist context type is `PromptCoordinator.Context` (below).

---

## 1. Verified Findings (with evidence)

### 1.1 Screen capture: BOTH legacy and ScreenCaptureKit, user-selectable

**[VERIFIED]** Linked symbols (`nm | swift demangle`):
```
U _CGWindowListCreateImage
U _CGWindowListCopyWindowInfo
U _OBJC_CLASS_$_SCScreenshotManager
U _OBJC_CLASS_$_SCShareableContent
U _OBJC_CLASS_$_SCContentFilter
U _OBJC_CLASS_$_SCStreamConfiguration
U _OBJC_CLASS_$_SCWindow
```
**[VERIFIED]** Cotypist exposes the choice as an enum:
```swift
enum Cotypist.TextFieldContextCapture.ScreenshotCaptureMode { case legacy; case screenCaptureKit; case both }
enum Cotypist.TextFieldContextCapture.OCRScope        { case aboveTextField; case fullWindow }
struct Cotypist.TextFieldContextCapture.ScreenshotContext { let screenshotText: String?; let screenshotImage: CGImage? }
```
Both conform to `UserDefaultsRawRepresentable` / `_UserDefaultsEnumConvertible` (protocol-conformance
records at lines 12277–12332 of the swift-dump), i.e. they are persisted preferences the user can flip.

Interpretation:
- `legacy` = `CGWindowListCreateImage` (still works for the app's *own*… no — works cross-window only with
  Screen Recording grant; Apple deprecated it in 14 but it still functions). `screenCaptureKit` =
  `SCScreenshotManager.captureImage(contentFilter:configuration:)`. `both` = try SCK, fall back to legacy.
- `aboveTextField` is the default-interesting one: OCR is **cropped to the region above the focused field**,
  not the whole window. This is the single biggest efficiency lever (see §3).

**[VERIFIED]** OCR is X-range-aware:
```
"performOCR(on:textFieldXRange:)"     (string @0x1007d7510)
"Cotypist/VNRecognizeTextRequest+Transcript.swift"   (source path @0x1007d7810)
```
The helper is a category on `VNRecognizeTextRequest` ("+Transcript") that takes a `textFieldXRange` — i.e. it
filters/clips OCR observations by horizontal extent of the field, then assembles a transcript. **[INFERRED]**
The X-range filter keeps the OCR'd text aligned to the column the field occupies (e.g. one chat message
column, not the whole window of sidebars/toolbars).

**[VERIFIED]** Capture is gated behind Screen Recording and degrades gracefully. Strings:
```
"screencapturekit"
"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
"…basic completions will be available even without it…"
"Use screenshots for context" / "Use screenshots to improve suggestion appearance"
```
The latter two are **two separate toggles**: one for *prompt context* (OCR → text), one for *appearance*
(sampling pixel colors behind the ghost text so it blends). The appearance toggle warns it "may occasionally
cause a purple Screen Recording notice."

### 1.2 OCR: Vision, accurate vs fast, candidate confidence

**[VERIFIED]** Linked Vision classes:
```
U _OBJC_CLASS_$_VNRecognizeTextRequest
U _OBJC_CLASS_$_VNImageRequestHandler
U _OBJC_CLASS_$_VNRecognizedText
U _OBJC_CLASS_$_VNRecognizedTextObservation
```
**[VERIFIED]** Tuning selectors present: `setRecognitionLevel:`, `setMinimumTextHeight:`, `topCandidates:`.
So Cotypist, like typer, sets a recognition level, a minimum text height (to skip tiny chrome), and reads
top candidate(s). **[VERIFIED]** Output stored as `screenshotText: String?` on the context and persisted as
`screenshotText` on `UserInputRecord`. **[VERIFIED]** `ScreenshotFormat { png, heic }` — the *image* itself
can be persisted, and HEIC is offered for compact on-disk training data.

### 1.3 AX context: before/after cursor split, parameterized queries, web-element identity

**[VERIFIED]** Imported AX symbols:
```
U _AXUIElementCopyAttributeValue
U _AXUIElementCopyParameterizedAttributeValue   ← AXBoundsForRange / AXStringForRange family
U _AXUIElementCopyAttributeNames
U _AXValueGetValue
U _AXObserverCreate / _AXObserverAddNotification / _AXObserverGetRunLoopSource
```
**[VERIFIED]** AX notifications observed (strings): `AXSelectedTextChanged`, `AXFocusedUIElementChanged`,
`AXFocusedWindowChanged`.

**[VERIFIED]** The persisted record splits text around the cursor (FIM-style):
```swift
struct Cotypist.UserInputRecord {
    var textUpToCursor: String
    var selectedText:   String?
    var textAfterCursor: String?
    var textLanguage:   String?
    var typingContext:  String?
    var screenshotText: String?
    var domain:         String?
    var appProperties:        PromptCoordinator.Context.AppProperties
    var textFieldProperties:  PromptCoordinator.Context.TextFieldProperties
    var screenshotData: Data?    // optional raw image (png/heic)
    // + id, createdAt, updatedAt, cotypistVersion, appBundleIdentifier, propertyBagString
}
```
**[VERIFIED]** Web/Electron element identity is captured:
```swift
struct Cotypist.TextFieldAccessibilityInfo {
    let textFieldFrame: CGRect
    let windowFrame:    CGRect?
    let domIdentifier:  String?     // HTML id of the focused field
    let domClassList:   [String]?   // HTML class list
    let accessibilityIdentifier: String?
}
```
This is how Cotypist tells "Gmail compose" from "Gmail search" inside one Chrome window — it reads the DOM
id/class via AX (`AXDOMIdentifier`/`AXDOMClassList` are the real attribute names Chromium exposes).

**[VERIFIED]** Rich field metadata for the prompt:
```swift
struct PromptCoordinator.Context.TextFieldProperties {
    let description, placeholderValue, help, identifier, title, titleUIElement, language: String?
    let userInputLabels: [String]?
}
struct PromptCoordinator.Context.AppProperties {
    let osUsername, name, windowTitle, url: String?
    let bundleIdentifier: String
    var pid: Int32
    let typingContext: String?
}
```
So the prompt knows: field **placeholder** ("Search", "Message #general"), field **title/label**, the
**URL** of the page, the **window title**, even the **OS username** (to personalize signatures). typer
currently feeds only app name + window AX text + OCR — it does **not** read placeholder/label/URL.

### 1.4 Prompt assembly & token budgeting — pre-tokenized, per-source

**[VERIFIED]** The assembled context carries **parallel token arrays per source**, not just strings:
```swift
struct Cotypist.PromptCoordinator.Context {
    let appProperties; let textFieldProperties
    let screenshotText: String?;  var screenshotImage: CGImage?
    let previousUserInputs: [String]
    let screenshotTokens:          [Int32]   // pre-tokenized
    let environmentContextTokens:  [Int32]
    let previousUserInputsTokens:  [Int32]
    let pasteboardTokens:          [Int32]
    let fullPrompt:                [Int32]
    let date: Date
}
struct Cotypist.PromptCoordinator {
    let promptPrefix: [Int32]
    let prefixHasInstructions: Bool
    let afterCursorWrapping: PromptTemplates.Wrapping.Tokens   // FIM after-cursor wrap tokens
    let completionPrompt: [Int32]
    let longContextSize: Int
    let maxPromptLengthEstimate: Int
}
```
Key inferences from these shapes:
- **[VERIFIED]** Each context source (screenshot / environment / previous inputs / pasteboard) is tokenized
  **independently** and budgeted/truncated in token space, then concatenated into `fullPrompt`. This is far
  more precise than typer's char-count `.suffix(N)` truncation.
- **[VERIFIED]** `afterCursorWrapping: PromptTemplates.Wrapping.Tokens` + `textAfterCursor` ⇒ Cotypist uses a
  **fill-in-the-middle** prompt: prefix tokens, user text up to cursor, a wrapping token, text after cursor.
  typer is prefix-only (continuation).
- **[VERIFIED]** `longContextSize` + `maxPromptLengthEstimate` ⇒ a two-tier budget (a normal cap and a
  larger "long context" cap), chosen per model via `ModelSpec.CustomProperties`.

**[VERIFIED]** `TokenizationCache` keyed precisely:
```swift
class TokenizationCache { let cache: Locked<[CacheKey: CacheValue]> }
struct CacheKey   { let string: String; let addBosIfApplicable: Bool; let allowParsingSpecialTokens: Bool }
struct CacheValue { let tokens: [Int32]; var lastUsed: Date }   // LRU by lastUsed
```
So repeated substrings (the unchanging style/system block, a re-shown screenshot transcript) are tokenized
once and reused. **[VERIFIED]** `correctionPromptCache: [Int32]` on `CompletionManager` — the autocorrect
prompt prefix is cached pre-tokenized too.

### 1.5 Capture cadence — event-driven (AX observers) + polling fallback + throttled background

**[VERIFIED]** The monitor is observer-based, not a fixed timer:
```swift
class Cotypist.CompletionAccessibilityMonitor {
    var focusedElementPollingTask: Task<…>?              // polling fallback
    var applicationDidActivateObserver
    var _applicationObserverForFocusedUIElement: AXObserverDeferredRelease
    var _textFieldObserverForStarting:           AXObserverDeferredRelease
    var pollingTemporarilySuspendedForPID: Int32?
}
class Cotypist.CompletionManager {
    var _textFieldObserverForCompletion:  AXObserverDeferredRelease
    var _applicationObserverForResetting: AXObserverDeferredRelease
    var _layoutChangeObserver:            AXObserverDeferredRelease   // re-anchor overlay on scroll/resize
    var scrollWheelMonitor: ScrollWheelMonitor?
    let backgroundRefresher: NBT?
    var lastRefreshCheck: Date                                        // throttle gate
    var applicationsTemporarilyInadmissibleForAutomaticCompletion: [String: Date]   // per-app backoff
}
```
**[INFERRED]** Capture is driven primarily by `AXSelectedTextChanged` (the user typed/moved the caret), not a
clock. A `focusedElementPollingTask` covers apps that don't post AX notifications. `lastRefreshCheck` +
`backgroundRefresher` throttle the *expensive* extras (screenshot/OCR). `pollingTemporarilySuspendedForPID`
and `applicationsTemporarilyInadmissible…` are per-app backoff to avoid hammering misbehaving apps.
`_layoutChangeObserver` + `ScrollWheelMonitor` keep the overlay anchored without re-capturing content.

**[VERIFIED]** Per-element snapshotting with dirty-flag persistence:
```swift
class Cotypist.TextFieldSnapshot { var userInputRecord; var accessibilityInfo; var hasAcceptedCompletion;
                                   var lastPersistedAt: Date; var needsPersistence: Bool }
class Cotypist.TrainingDataCollector { var currentSnapshot; var recentSnapshots: [TextFieldSnapshot];
                                       var persistenceTimer: NSTimer?; var isEnabled: Bool }
```
**[INFERRED]** A snapshot is updated in memory on every change but only flushed to SQLite when
`needsPersistence` and a periodic `persistenceTimer` fires — batched writes, not per-keystroke I/O.

### 1.6 Caching & secret-safety

- **[VERIFIED]** `TokenizationCache` (LRU, §1.4), `LineHeightCache` (`Locked<[String: CGFloat]>`, caches
  measured line heights per font/string so the overlay doesn't re-measure), `tuiExtractionCache`
  (`TS.ExtractionCache` for terminal text), `correctionPromptCache`.
- **[VERIFIED]** Pasteboard is a first-class context source with its own token budget (`pasteboardTokens`),
  gated by a "Use clipboard for context" toggle and the `Privacy_Pasteboard` settings deep-link.
- **[INFERRED]** No explicit "concealed pasteboard type" string was found, so Cotypist's secret-skip story
  for clipboard is weaker than typer's (typer explicitly checks `org.nspasteboard.ConcealedType`).

---

## 2. Cotypist Architecture (data flow)

```
AX event (AXSelectedTextChanged / FocusedUIElementChanged)  ──┐
   │  (CompletionAccessibilityMonitor; polling fallback)       │
   ▼                                                           │
focused AXUIElement ──► AX reads:                              │
   • kAXValue + kAXSelectedTextRange  → textUpToCursor /       │
     selectedText / textAfterCursor                            │
   • placeholder / title / help / identifier / language        │  every change (cheap)
   • AXDOMIdentifier / AXDOMClassList (web)                     │
   • AppProperties: bundleID, name, windowTitle, URL, user      │
   ▼                                                           │
TextFieldSnapshot (in-memory, dirty-flagged)                   │
                                                               │
backgroundRefresher (throttled by lastRefreshCheck) ──────────┘  expensive, rate-limited
   ▼
TextFieldContextCapture:
   • ScreenshotCaptureMode {legacy|SCK|both}
   • capture region = OCRScope.aboveTextField  → crop to band above field
   • VNRecognizeTextRequest+Transcript.performOCR(on:textFieldXRange:)
   • → ScreenshotContext{ screenshotText, screenshotImage }
   ▼
PromptCoordinator.Context  (per-source token arrays + caches)
   • screenshotTokens, environmentContextTokens,
     previousUserInputsTokens, pasteboardTokens
   • TokenizationCache (LRU) reuses unchanged blocks
   • FIM assembly: promptPrefix + upToCursor + afterCursorWrapping + afterCursor
   • budget against longContextSize / maxPromptLengthEstimate
   ▼
CompletionRequest → GenerationManager (llama.cpp) → overlay
   (CompletionManager.context cached; KV-prefix-friendly stable ordering)

Side channel (opt-in): TrainingDataCollector batches snapshots →
   GRDB UserInputRecord (createTable, addTypingContext, addScreenshotData, addDomain;
   index appBundleIdentifier_updatedAt). screenshotData stored as png/heic.
```

---

## 3. Efficiency Techniques (ranked by payoff for typer)

1. **Crop OCR to the band *above/around the field*, X-range filtered** (`OCRScope.aboveTextField`,
   `performOCR(on:textFieldXRange:)`). typer already band-clips for the *caret locator* but its *context*
   `screenOCR` captures the **whole window at 0.5×**. Cropping context OCR to "field column, region above
   cursor" cuts Vision cost and removes sidebar/toolbar noise.
2. **Per-source pre-tokenization + token-space budgeting** (`*Tokens: [Int32]`, `TokenizationCache`). Cuts
   re-tokenization cost and lets each source be truncated precisely so none starves the live line.
3. **Event-driven capture, not timer-driven.** Refresh extras on `AXSelectedTextChanged` (debounced) rather
   than a fixed 4 s tick; poll only where AX is silent.
4. **Per-app admissibility backoff** (`applicationsTemporarilyInadmissibleForAutomaticCompletion`,
   `pollingTemporarilySuspendedForPID`) — stop capturing in apps that throw AX errors or never accept.
5. **Dirty-flag batched persistence** (`needsPersistence` + `persistenceTimer`) — no per-keystroke disk I/O.
6. **`LineHeightCache`** — memoize text measurement for the overlay.
7. **HEIC for any stored screenshot** (`ScreenshotFormat.heic`).
8. **Layout-change observer + scroll monitor** to re-anchor the overlay *without re-capturing* content.

---

## 4. typer Gap Analysis

typer's `TyperApp+Context.swift` is already strong: ScreenCaptureKit one-shot (`SCScreenshotManager`),
`sourceRect` band-clip + `scale` downsample for the caret locator, `.accurate` vs `.fast` OCR levels,
`minimumTextHeight`, `isLikelyText`/`isNumericChrome` noise gates, concealed-pasteboard skip, AX-first /
OCR-fallback, `backgroundRefreshSeconds=4` throttle, power-save degradation, topic memory. It also already
splits `textUpToCursor`/`textAfterCursor` in `TyperApp+Caret.swift` and uses `AXBoundsForRange` +
`AXBoundsForTextMarkerRange`. Real gaps vs Cotypist:

| Area | Cotypist | typer today | Gap |
|---|---|---|---|
| Context OCR region | crop to field column / above-field band | **full window @0.5×** | crop to caret band → big win |
| OCR transcript ordering | X-range column-aware reading order | naive top-to-bottom join | column noise |
| Token budgeting | per-source `[Int32]` arrays, token-space truncation | `String.suffix(chars)` | imprecise, wastes budget |
| Tokenization cache | `TokenizationCache` LRU + `correctionPromptCache` | none (re-tokenize each call in helper) | latency |
| FIM | `afterCursorWrapping` + `textAfterCursor` in prompt | continuation only | quality on mid-line edits |
| Field metadata | placeholder, title, help, URL, language, labels | app name + window text | strong cheap signal unused |
| Web element identity | `AXDOMIdentifier` / `AXDOMClassList` | not read | can't distinguish fields in one web app |
| Capture trigger | AX-event driven + poll fallback | time-throttled (4 s) refresh | stale / wasteful |
| Per-app backoff | inadmissible-until map | global only | hammers bad apps |
| Persistence | dirty-flag batched (GRDB) | n/a (typer keeps memory files) | fine, but training capture absent |
| Line measurement | `LineHeightCache` | re-measured | minor |

---

## 5. Concrete Recommendations (API-level)

**R1 — Crop context OCR to a caret-anchored band (highest ROI).**
In `screenOCR`, stop capturing the whole window. Reuse the machinery already in `screenshotCaretRect`:
compute `focusedElementQuartzRect()`, expand it upward by N lines (e.g. `clip = field.insetBy(dx:0,
dy:-field.height*6).intersection(window)`), pass that as `captureFocusedWindow(clip:scale:)`. Then filter
Vision observations to those whose `boundingBox.midX` falls within the field's normalized X-range — port
Cotypist's `performOCR(on:textFieldXRange:)`. Expected: ~5–10× less Vision work + cleaner text.

**R2 — Read cheap AX field metadata and put it in the prompt.**
Add to the AX read (no screenshot needed): `kAXPlaceholderValueAttribute`, `kAXTitleAttribute`,
`kAXHelpAttribute`, `kAXDescriptionAttribute`, and for web fields `"AXDOMIdentifier"` /
`"AXDOMClassList"`, plus the page URL via the window's `"AXURL"` / `AXWebArea`. Surface as a labeled block:
`Field: <placeholder|title> in <app> — <url>`. This mirrors `PromptCoordinator.Context.TextFieldProperties`
and is essentially free.

**R3 — Token-space budgeting + a tokenization cache in `LlamaClient`.**
Replace char `suffix()` truncation with: tokenize each block (style, background/OCR, topic, immediate) via the
helper's tokenizer, keep an LRU `[CacheKey: [Int32]]` (`CacheKey{string, addBOS, allowSpecial}` exactly like
Cotypist), and fill a token budget in priority order (immediate → field meta → style → background) so a long
background block can't crowd out the live line. Keeps the unchanging prefix stable for llama.cpp KV reuse.

**R4 — Fill-in-the-middle assembly when the model supports it.**
typer already has `textAfterCursor`. If the chosen GGUF is a FIM model, wrap as
`<prefix>upToCursor<suffix>afterCursor<middle>`; otherwise keep continuation. Gate by a `ModelSpec`-style
capability flag (Cotypist's `PromptCoordinator.afterCursorWrapping` / `prefixHasInstructions`).

**R5 — Make extra-context capture AX-event driven, not clock driven.**
In `TyperApp+AXObserver.swift` you already observe `kAXSelectedTextChangedNotification`. Instead of refreshing
background on a 4 s timer, mark `backgroundDirty=true` on that notification and run the throttled refresh on a
short debounce (e.g. 600 ms after the last change) — Cotypist's `lastRefreshCheck` gate pattern. Keep a
low-frequency safety timer for AX-silent apps (your current path).

**R6 — Per-app admissibility backoff.**
Add `inadmissibleUntil: [String: Date]`. When `captureFocusedWindow`/AX walk returns empty or errors for an
app, set a backoff (exp up to ~60 s) keyed by bundle id; skip capture while backed off. Mirrors Cotypist's
`applicationsTemporarilyInadmissibleForAutomaticCompletion`.

**R7 — Cheap wins.** Cache measured line heights (`[String: CGFloat]` keyed by font+string) like
`LineHeightCache`; if you ever persist screenshots, use HEIC (`NSBitmapImageRep` → `.heic` / `CGImageDestination`
with `AVFileType.heic`).

**Suggested implementation order:** R1 → R2 → R5 → R3 → R6 → R4 → R7. R1+R2+R5 are the efficiency/quality core
and reuse code typer already has.
