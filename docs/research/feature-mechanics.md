# Cotypist Feature Mechanics — Reverse-Engineering Notes for typer

Target: `/Applications/Cotypist.app` (CFBundleShortVersionString **2026.1**, build **73**).
Method: `ipsw class-dump`, `ipsw swift-dump`, `ipsw macho info --strings`, `otool -tV` (symbolicated literal-pool refs), `zstd -dc` on resources.

Conventions in this doc:
- **VERIFIED** = directly observed in the binary (class layout, string, selector, or disassembly).
- **INFER** = reconstructed from partial evidence + standard macOS practice; flagged as such.
- Swift type names are de-mangled where `ipsw swift-dump` printed them; raw mangled names (`_$s...`) are left as-is.

Cotypist is a non-sandboxed AppKit app, llama.cpp via bundled `libllama.0.dylib` + ggml (`libggml-metal/-cpu/-blas/-base`), state in **GRDB** (SQLite), updates via **Sparkle**, crash/telemetry via **Sentry**, support chat via **RepliesSDK**, hotkeys via **MASShortcut**.

---

## 1. Per-app custom instructions

### Verified evidence
- GRDB record type:
  ```
  struct Cotypist.AppOverrideRecord { var id: String; var overrides: Cotypist.AppOverrides; var updatedAt: Date }
  enum Cotypist.AppOverrideRecord.CodingKeys { id, overrides, updatedAt }
  enum Cotypist.AppOverrideRecord.Columns {}        // GRDB Columns helper
  ```
  String `"AppOverrideRecord.createTable"` confirms a GRDB migration. `id` is the **bundle identifier** (apps) or a **domain pattern** (web; see `Cotypist.DomainPattern` / `DomainPattern.Specificity`). `overrides` is a Codable blob (JSON) stored in one column; `updatedAt` enables last-writer-wins sync.
- The override payload (full field list — VERIFIED from `struct Cotypist.AppOverrides`):
  ```
  completionsDisabled, midLineCompletionsDisabled, autocorrectDisabled,
  tabShortcutsDisabled, smartQuotesDisabled, textMirroringEnabled,
  ignoreSizeThresholds, emojiCompletionsDisabled, emojiSearchDisabled,
  requiresNonBreakingSpaceWorkaround, requiresSpaceKeyEventWorkaround,
  requiresPasteAndMatchStyleWorkaround, requiresBackspaceRightAfterPaste,
  stringInjectionChunkSize, fontSizeAdjustmentFactor, verticalAlignmentOffset,
  needsEnhancedUserInterface, trainingDataCollectionDisabled, customInstructions
  ```
  Every field is **optional** (`_$sSbSg` = `Bool?`, `_$sSSSg` = `String?`), so an override only carries the keys the user changed; everything else falls through to global. `customInstructions: String?` is the per-app instruction text.
- `struct AppOverrides.PropertyInfo { name; label; isUserVisible: Bool; appOnly: Bool }` — drives the settings UI: which override rows are shown to users vs. internal compatibility flags, and which apply only to native apps (not web domains).
- Storage/merge plumbing:
  - `AppOverridesStore` holds `databaseQueue: GRDB.DatabaseQueue?`, an in-memory `Locked<[String: AppOverrides]> cache`, and `Locked<[UUID: ([String:AppOverrides])->()]> observers` (observer registry keyed by UUID token).
  - `AppOverridesManager { store; observers; storeObserverToken }` is the public API the rest of the app talks to.
  - UI: `AppOverridesSettingsPane` (SwiftUI) → `AppOverridesSettingsViewModel` (`@Published entries/selectedEntryID/showAllSettings`, 4 `PreferenceObserverToken`s) → `AppOverrideDetailView`. `OverrideEntry` carries `resolvedOverrides` (merged result) and `userOverrides: AppOverrides?` (just the user's deltas) side-by-side — proving an explicit **resolve = merge(inCode defaults, userOverrides)** step. String `"AppOverrideDetailView.CustomInstructions"` is the per-app instruction text field; `"PersonalizationSettingsPane.CustomInstructions"` and `"Plus.GlobalCustomInstructions"` are the global field.
- Merge into the prompt (VERIFIED structurally): `PromptCoordinator.customProperties: ModelSpec.CustomProperties?` holds the prompt templates + biases; the user-instruction text is tokenized once into `PromptCoordinator.userPromptTokens: [Int32]?` and wrapped by `PromptTemplates.Wrapping.userPrompt` (a `(before, after)` string pair). The instructions live in their own prompt section (see §enum `PSID` below: there is no separate "instructions" section id — it is prepended as `userPromptTokens` ahead of `completionPrompt`, and `prefixHasInstructions: Bool` records whether the cached prefix already contains them so the KV-cache prefix can be reused).

### Tiering gate (VERIFIED)
Strings `"Pro.PerAppCustomInstructions"` and `"Plus.GlobalCustomInstructions"` show per-app instructions are a **Pro** entitlement and a single global instruction is **Plus**.

### Implementation recipe for typer
- Schema (SQLite, mirror GRDB): table `app_override(id TEXT PRIMARY KEY, overrides BLOB /*JSON*/, updated_at REAL)`. `id` = bundle id, or a `domain:<pattern>` row for web. Store the override as a JSON object of only-changed keys (all-optional struct), matching `AppOverrides`. typer's `TyperConfig.swift` is the natural home for the Codable struct; persist via SQLite (typer already ships no DB — a single JSON file keyed by bundle id is acceptable at typer's scale, but keep `updatedAt` for future sync).
- Resolve order: `resolved = global.merged(with: appOverride).merged(with: domainOverride)` where each non-nil field wins. Expose `resolvedOverrides` AND `userOverrides` to the settings UI so users see "inherited vs. overridden."
- Prompt merge: build `globalInstructions + "\n" + perAppInstructions` (per-app appended last so it can override tone), tokenize once, and cache as the prompt prefix. Set a `prefixHasInstructions` flag so `ModelRouter`/completion code knows whether to invalidate the KV-cache prefix when instructions change (`resetCompletionManagerDueToUserPromptChange` is Cotypist's selector for exactly this — wire an equivalent in typer's `TyperApp+Completion.swift`).

---

## 2. Timed snooze ("Completions disabled for the next X minutes/seconds")

### Verified evidence
- Format strings: `"Completions disabled for the next %.0f seconds"` and `"...%.0f minutes"`; localized table keys `"Status Item Menu: Completions disabled for the next seconds."` / `"...minutes."`.
- State lives on `CompletionManager`:
  ```
  var allCompletionsDisabledUntil: Date?
  var applicationsTemporarilyInadmissibleForAutomaticCompletion: [String: Date]   // bundleId -> until
  ```
  So **global snooze** = one `Date?`; **per-app snooze** = a dict of `bundleId → expiry Date`. This is a *deadline* model, not a running timer — every completion attempt compares `Date.now` against the stored deadline (no `NSTimer` needed for correctness; a timer is only used to refresh the menu label/clear the menu state).
- Menu actions (ObjC selectors on `ModelRepository`, which also owns the `NSStatusItem`):
  `toggleCompletionsForCurrentApp:`, `toggleCompletionsGlobally:`, plus `enableCompletionsGlobally:`, `disableCompletionsGlobally:`, `enableCompletionsForApplication:`, `excludeApplication:`, `includeApplication:`. String symbols `"ModelRepository.toggleCompletionsForCurrentApp"` / `".toggleCompletionsGlobally"` confirm the Swift funcs.
- Disassembly of the menu-update path constructs the `%.0f minutes`/`%.0f seconds` string by computing `floor(remaining/60)*60` style rounding (observed `fdiv`/`frinta`/`fmul` by `0x4059000000000000` = **100.0**… actually `64.0`-region constant; rounding of the countdown) — i.e. the label is recomputed from `allCompletionsDisabledUntil - Date.now`.

### Implementation recipe for typer
- Add to typer's completion controller:
  ```swift
  var allCompletionsDisabledUntil: Date?
  var perAppDisabledUntil: [String: Date] = [:]   // bundleId -> deadline
  func completionsAllowed(bundleID: String) -> Bool {
      let now = Date()
      if let g = allCompletionsDisabledUntil, g > now { return false }
      if let a = perAppDisabledUntil[bundleID], a > now { return false }
      return true
  }
  ```
- Menu: build submenu "Snooze for…" with 5/15/60 min items that set the deadline; one repeating `Timer` (1 Hz while a deadline is active) that only refreshes the status-item title/menu and clears expired deadlines. Gate the deadline read in the AX-observer completion trigger (`TyperApp+AXObserver.swift` / `TyperApp+Completion.swift`). No persistence needed — snooze is intentionally session-scoped.

---

## 3. Disable macOS native inline prediction

### Verified evidence — this was a key find
- The clash is with Apple's **`NSAutomaticInlinePredictionEnabled`** UserDefaults/CFPreferences key (macOS Sonoma+ inline predictions in `NSTextView`/`UITextView`). String present verbatim.
- **Detection** (VERIFIED via disassembly at `0x100379bd4`):
  ```
  ldr  x0, ["NSAutomaticInlinePredictionEnabled" (cached NSString)]
  ldr  x1, [_kCFPreferencesAnyApplication]
  bl   _CFPreferencesGetAppBooleanValue          ; (key, kCFPreferencesAnyApplication, NULL)
  ```
  Cotypist reads the **global** preference domain (`kCFPreferencesAnyApplication`) to learn whether Apple inline prediction is on system-wide, and records it as telemetry fields `inlinePredictionDisabled` / `inlinePredictionEnabledAtPresentation`.
- The user-facing flow is `InlinePredictionDisableController : StackedElementsViewController` (an onboarding "what's new" screen, conforms to `WhatsNewScreenController`) with:
  ```
  inlinePredictionCheckbox: NSButton
  inlinePredictionEnabledAtPresentation: Bool
  func disableButtonAction()      // symbol "InlinePredictionDisableController.disableButtonAction"
  ```
  i.e. Cotypist does **not** silently fight Apple's feature; it detects the conflict and presents a one-click screen that flips the preference. The bridged NSString global at `0x100444ab4` is the key it writes.

### How the write almost certainly works (INFER — write path not fully disassembled)
Apple exposes inline prediction only via the `NSAutomaticInlinePredictionEnabled` default. Cotypist cannot toggle it inside the *target* app's text view (it doesn't own it), so `disableButtonAction()` writes the key to the **global** domain: `CFPreferencesSetValue("NSAutomaticInlinePredictionEnabled", kCFBooleanFalse, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)` then `CFPreferencesSynchronize`. Effect: new text views read the global default and disable Apple predictions, removing the visual collision with Cotypist's ghost text. (Detection uses `GetAppBooleanValue` on the same key/domain, which is the strong evidence the write targets that same key/domain.)

### Implementation recipe for typer
- Detect at startup and on app-focus: `CFPreferencesGetAppBooleanValue("NSAutomaticInlinePredictionEnabled" as CFString, kCFPreferencesAnyApplication, nil)`. If `true`, show a non-modal banner/onboarding card.
- Offer one-click disable: `CFPreferencesSetValue(... kCFBooleanFalse, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost); CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)`. Record `enabledAtPresentation` so you can offer to restore it on uninstall. Add this controller alongside typer's existing AX-permission onboarding.
- Note: this is a global toggle and requires a relaunch of the target app to take full effect — message accordingly.

---

## 4. Multi-candidate suggestion picker

### Verified evidence
- `SuggestionsTableViewController : NSViewController <NSTableViewDelegate, NSTableViewDataSource>`:
  ```
  tableViewContainer: NSView; tableView: NSTableView;
  suggestionTextTruncationMode: NSLineBreakMode; suggestions: [String]
  ```
  Plain `NSTableView` (one column, `tableView:viewForTableColumn:row:`), rows are `SuggestionsTableCellView : NSTableCellView`. Source file `Cotypist/SuggestionsTableViewController.swift`.
- It is hosted in a borderless window: `SecondarySuggestionsOverlayWindow : NSWindow` → `SecondarySuggestionsOverlayViewController` → owns the table VC. The primary inline ghost text is a *separate* path (`SingleCompletionOverlayWindow` / `CompletionOverlayManager`). `CompletionManager` holds both `secondarySuggestionsOverlayWindow?` and `suggestionsTableViewController?`.
- `maxResultsToShow`, `maxResultWidth`, `maxSearchWidth` on `CompletionManager` (and mirrored on `GenerationManager`) bound how many candidates the table shows and how wide the search beam is.

### "userDidVoteForSuggestion" — important correction
`replies:userDidVoteForSuggestion:` is a method of **`RepliesIODelegate`** (the third-party **RepliesSDK** support-chat framework), implemented by `Cotypist.SupportRequests : RepliesIODelegate`. **It is NOT the autocomplete feedback signal** — it is up/down voting on canned support replies. There is **no verified telemetry vote on autocomplete candidates**; candidate selection feedback, if any, would flow through the training-data pipeline (`NBT`/`DatabaseManager`, `enableTrainingDataCollection`). Do not copy a "vote" API expecting it to improve completions.

### Implementation recipe for typer
- Generate N candidates with a small beam / multiple samples (typer already has `ModelRouter`; expose `maxResultsToShow` ~3–5). Show them in a borderless `NSWindow` anchored under the caret (reuse typer's `SuggestionOverlay.swift`/caret anchoring from `TyperApp+Caret.swift`), backed by an `NSTableView` + custom cell. Accept via ↑/↓ + Tab/Return; keep the top candidate as the inline ghost.
- For a real learning signal, log `(context, shownCandidates, acceptedIndex)` to a local store and feed it to KTO/personalization — not a separate "vote" UI.

---

## 5. Emoji completion

### Verified evidence — data fully decoded
Resource dir `/Contents/Resources/emoji/`, all **Zstandard-compressed** (`zstd -dc`):
| file | decompressed | format |
|---|---|---|
| `emoji_shortcode_list_merged_no_modifiers.bin` | 84,138 B | lines of `:shortcode: <emoji>` (also ASCII emoticons: `:) 😊`, `:-D 😄`, `:+1: 👍`) |
| `emoji_list_non_modifiable.bin` | 9,776 B | one emoji per line (no skin-tone variants apply) |
| `emoji_list_modifiable_base.bin` | 3,175 B | base emoji that accept skin-tone modifiers |
| `emoji_gender_variants.bin` | 3,902 B | TSV `neutral⇥male⇥female` (e.g. `🏃\t🏃‍♂️\t🏃‍♀️`) |

Code: `enum EmojiCompletionSupport` with
```
enum CompletionType { case emojiSearchFiltered(typedShortcodePrefix); emojiSearchLegacy(typedShortcodePrefix); regular; emoji; none }
```
plus runtime prefs `EmojiSkinTonePreference {neutral,light,mediumLight,medium,mediumDark,dark}`, `EmojiGenderPreference {neutral,female,male}`, `struct EmojiInventory.GenderForms {neutral; male?; female?}`, and the completion request carries `expansionLimit`, `prefixExpansionLimit`, `transitionExpansionLimit`, `requiredPrefixBytes`. Per-app gates: `emojiCompletionsDisabled`, `emojiSearchDisabled` (in `AppOverrides`); global pref `emojiCompletionsDisabled`. Feature flag `featureEmojiCompletion`.

### Mechanics (INFER from the above)
Two modes: (a) **inline expansion** — when the user types a recognized `:shortcode:` or emoticon, replace with the emoji (the merged map); (b) **emoji search** — typing `:par` filters shortcodes by `typedShortcodePrefix` and shows a candidate list (the `emojiSearch*` cases). Skin tone: if the matched base is in `emoji_list_modifiable_base`, apply the Fitzpatrick modifier for the user's `EmojiSkinTonePreference`; non-modifiable list short-circuits that. Gender: look up `GenderForms` to pick neutral/male/female form.

### Implementation recipe for typer
- Ship the same three data sets (shortcode map, modifiable-base set, gender-variants TSV) — these are derived from public emoji data (gemoji-style). Store as a compressed resource; decode once at launch into `[String:String]` (shortcode→emoji) + `Set<String>` (modifiable) + `[String:GenderForms]`.
- Matching: on each keystroke, if current word matches `:<prefix>`, run prefix search over shortcode keys (cap results with an `expansionLimit`). Apply skin-tone (append U+1F3FB…U+1F3FF when base ∈ modifiable set) and gender from a single user preference. Surface in the same candidate overlay as §4. Gate per-app via the override fields.

---

## 6. Model catalog & hardware tiering

### Verified evidence — full model list
Source files `ModelRepository+ModelsList.swift`, `TierModelSwapNotice.swift`. `enum ModelSpec.Host { huggingFace(repository); cotypist(creator); local }` — models pull from HF or `https://models.cotypist.app/`. Repos/quants observed (string table):

| Display | HF repo | quant string | base/instruct |
|---|---|---|---|
| gemma-3-270m | `ggml-org/gemma-3-270m-GGUF` | — | (small) |
| Gemma 3 Instruct 1B | `unsloth/gemma-3-1b-it-GGUF` | `gemma-3-1b-it-UD-Q4_K_XL` | instruct (-it) |
| gemma-3-1b-pt | `mradermacher/gemma-3-1b-pt-i1-GGUF` | i1 | **base (-pt)** |
| Gemma 3 Instruct 4B | `unsloth/gemma-3-4b-it-GGUF` | `gemma-3-4b-it-UD-Q4_K_XL` | instruct |
| gemma-3-4b-pt | `mradermacher/gemma-3-4b-pt-i1-GGUF` | i1 | **base (-pt)** |
| Llama 3.2 Instruct 1B | `unsloth/Llama-3.2-1B-Instruct-GGUF` | `...UD-Q5_K_XL` | instruct |
| Llama 3.2 Instruct 3B | `unsloth/Llama-3.2-3B-Instruct-GGUF` | `...UD-Q4_K_XL` | instruct |
| Qwen 3 Instruct 0.6B | `unsloth/Qwen3-0.6B-GGUF` | — | instruct |
| Qwen3-0.6B-Base | `mradermacher/Qwen3-0.6B-Base-i1-GGUF` | i1 | **base** |
| Qwen 3 Instruct 1.7B | `unsloth/Qwen3-1.7B-GGUF` | — | instruct |
| Qwen3-1.7B-Base | `mradermacher/Qwen3-1.7B-Base-i1-GGUF` | i1 | **base** |
| Qwen 3 Instruct 4B | `unsloth/Qwen3-4B-GGUF` | — | instruct |
| Qwen3-4B-Base | `mradermacher/Qwen3-4B-Base-i1-GGUF` | i1 | **base** |
| Qwen 3 Instruct 8B | `unsloth/Qwen3-8B-GGUF` | — | instruct |
| Qwen 3 Instruct 30B A3B | `unsloth/Qwen3-30B-A3B-GGUF` | — | instruct (MoE) |
| Qwen3-30B-A3B-Base | (HF, `unsloth/Qwen3-30B-A3B-GGUF` base variant) | — | base |

`ModelSpec` fields (VERIFIED): `identifier, localIdentifier?, quantization?, quantizationDelimiter, host, displayName, description?, size?, runtimeMemorySize?, family, isBaseModel: Bool, adapter?, availableAdapters: [String], customProperties`. So each entry knows its on-disk **size** and **runtimeMemorySize** (RAM footprint) separately, and whether it `isBaseModel`.

### Tiering
- `enum CPUTier { low, standard, high, veryHigh }`; `struct …{ model: ModelSpec; minimumMemoryGB: Double; recommendedCPUTier: CPUTier }`; `struct ModelRecommendation { ideal: ModelSpec; suitableModels: [ModelSpec]; cpuMismatchedModels: Set<String> }`.
- Disk pre-check (VERIFIED strings): `"A new recommended AI model, %@, is available!\n…requires %@ of free disk space, which doesn't appear to be available…"`, `"For better performance, a larger model would be recommended, but it requires %@ of free disk space…"`, and validation keys `"Model File Size Valid"`, `"Couldn't check file size of attachment with path: "`. So: before download, check free space ≥ model `size`; after download, validate the file's byte size against the expected size.
- `TierModelSwapNoticeView` + `RecommendedModelUpdateController` (states `needsAction / downloading / actionCompleted`, with `NSProgressIndicator` + a `fractionCompletedObserver` KVO on the download task) drive the "switch to a better model" UX. `recommendedModel` / `recommendedModelIsDownloaded` / `recommendedModelUpdateController.willAbortOnboarding` track this. Download runs through `DownloadAndRenameTask` (download to temp, validate, atomic rename).

### Implementation recipe for typer
- Model catalog as a static `[ModelSpec]` with `{repo, quantFile, sizeBytes, runtimeMemBytes, isBaseModel, minMemoryGB, recommendedCPUTier}`. typer already routes raw vs distilled in `ModelRouter.swift`; add the tier metadata there.
- Recommendation: read `ProcessInfo.processInfo.physicalMemory` and CPU class (`sysctlbyname("hw.perflevel0.physicalcpu")` for P-cores, or `hw.model`) → bucket into a CPUTier → pick the largest model whose `minMemoryGB ≤ physical RAM` and tier ≤ device tier.
- Download (`ModelDownloader.swift`): pre-check `URLResourceValues.volumeAvailableCapacityForImportantUsage ≥ sizeBytes + margin`; download to `*.partial`, observe `URLSessionDownloadTask.progress.fractionCompleted` via KVO for a progress bar, **validate final byte size == expected** (HTTP `Content-Length` / known size), then atomic `FileManager.replaceItemAt`. Surface a "better model available" notice when device RAM increases or a new catalog ships.
- Per typer's MEMORY: base (`-pt`/`-Base`) vs instruct matters because typer distills its own; Cotypist confirms shipping **both** base and instruct GGUFs and applying a **LoRA adapter** on top (see §7).

---

## 7. Personalization strength

### Verified evidence — it scales a LoRA adapter
- `enum PersonalizationStrength { off, subtle, light, standard, strong, max }` (6 levels).
- UI strings: `"Personalization strength"`, `"How strongly Cotypist leans suggestions toward your own writing style."`, and the long help: `"Uses your typing history to slightly favor the words and phrases you prefer. Subtle at lower values; too high may occasionally suggest a less fitting word."` Pref key `"PersonalizationSettingsPane.PersonalizationStrengthSlider"`.
- The thing it scales is a **LoRA adapter on the GGUF model**: strings `"Select a LoRA adapter to customize the model behavior."`, `"Selected Adapter"`, `"Successfully loaded adapter: "`; `ModelSpec` has `adapter: String?` + `availableAdapters: [String]`; `ModelRepository` has `selectedAdapter` get/set. `ModelSpec.CustomProperties { promptTemplates; biases: [String:Float] }`.

### Mechanics (INFER, well-supported)
The slider maps each `PersonalizationStrength` case to a **LoRA scale** passed to llama.cpp (`llama_set_adapter_lora(ctx, adapter, scale)` / older `llama_lora_adapter_set`). `off` ⇒ scale 0 (adapter detached); `max` ⇒ scale ~1.0+. The adapter itself is trained locally from the user's typing history (the `NBT` background trainer + `DatabaseManager`). The `biases: [String:Float]` map is a separate, lighter mechanism (token/word **logit biases** applied at sampling) that can also "favor words you prefer" without a trained adapter.

### Implementation recipe for typer
- Train a small per-user LoRA from logged accepted completions (typer's KTO pipeline already exists). At inference, attach with `llama_adapter_lora` and scale = `strengthToScale(level)` where e.g. `{off:0, subtle:0.25, light:0.4, standard:0.6, strong:0.8, max:1.0}`. Re-attach on slider change; no re-load of the base model needed.
- Cheaper interim: a `[token:Float]` logit-bias map built from the user's high-frequency words, added to logits before sampling. Wire into `ModelRouter.swift`’s sampler. This matches Cotypist's `biases` field and works even before a LoRA is trained.

---

## 8. Completion length control

### Verified evidence
- Pref key `"GeneralSettingsPane.MaxCompletionLength"`, label `"Maximum completion length"`. Discrete buckets (strings):
  `Short (~ 1 – 2 words)`, `Medium (~ 2 – 4 words)`, `Long (~ 4 – 7 words)`, `Very Long (~ 7 – 10 words)`, `Ultra Long (~ 10 – 15 words)`.
- Backing field: `GenerationManager.maxCompletionLength: Int` (also `AppOverridesStore`-level `maxCompletionLength`). It bounds the generation loop (token cap), distinct from `maxPromptTokens`/`maxPrefixLength`.

### Implementation recipe for typer
- Map each bucket to a **max new tokens** cap (e.g. words×~1.6 tokens) and pass as the generation stop budget in `ModelRouter`/`TyperApp+Completion.swift`. Also stop early on sentence/clause boundaries so "Long" doesn't pad. Expose as a 5-stop segmented control in settings; allow per-app override (Cotypist plumbs `maxCompletionLength` through `AppOverrides` indirectly via `ignoreSizeThresholds`/length).

---

## 9. Suggested fixes (typo) styling

### Verified evidence
- Toggle: `"GeneralSettingsPane.ShowSuggestedFixes"`, UI `"When a likely correction is available, show it inline as a strikethrough on the typo with the fix next to it."`
- Colors (named asset/colors): `autocorrectCorrectionGreen`, `autocorrectStrikethroughRed`, and a `"strikethrough"` attribute. So the render is: **typo drawn with red strikethrough**, **fix drawn in green** immediately after — inline, in the ghost overlay.
- Separate, distinct toggle: `"Don't show completions when typo suspected"` (key around `inlinePredictionDisabled`-adjacent strings) with help `"Holds back suggestions when Cotypist suspects you've made a typo, so it doesn't build on the mistake."` and `"Hides the completion when Cotypist suspects a typo in the word you're currently typing… only ever looks at the current word…"`. Field `autocorrectDisabled` per app; per-word correction state `correctionsByWord: [String: ACS.ACR]` and `correctionPromptCache` on `CompletionManager` (corrections are model-generated, cached per word).
- `autocorrectInfo` is the struct carried into the overlay describing what to strike/replace.

### Implementation recipe for typer
- Two independent settings: (a) **Show suggested fixes** (render correction inline), (b) **Suppress completion when typo suspected** (don't extend a misspelled word).
- Rendering in `GhostView.swift`/`SuggestionOverlay.swift`: build an `NSAttributedString` where the typo span gets `.strikethroughStyle` + red, and the suggested fix gets green; place the fix adjacent. Reuse typer's existing ghost layout.
- Detection: a cheap current-word spellcheck via `NSSpellChecker.shared.checkSpelling(of:startingAt:)` (single-word scope, matches Cotypist's "current word only" caveat), or have the model emit a correction token. Cache `correctionsByWord` so you don't re-query per keystroke.

---

## 10. Sparkle auto-update wiring

### Verified evidence (Info.plist)
```
SUFeedURL                = https://cotypist.app/updates/cotypist.xml
SUPublicEDKey            = ad5nJhJt8CuRUbH3Uz/lP48d7unnj6CpKd0y9oFVyMI=   (EdDSA / ed25519)
SUEnableAutomaticChecks  = true
SUScheduledCheckInterval = (set)
```
Sparkle.framework bundled; driver class `SPUStandardUserDriver` (string `@"SPUStandardUserDriver"`). Menu action `checkForUpdates:` on `ModelRepository`. Appcast is a standard Sparkle XML at a static URL; updates signed with the ed25519 public key above.

### Implementation recipe for typer
- Add Sparkle (SPM `Sparkle`), set `SUFeedURL` to typer's appcast (`https://<host>/appcast.xml`), generate an EdDSA key pair (`generate_keys`), put the **public** key in `SUPublicEDKey`, sign each build's appcast with the private key (`sign_update`). Set `SUEnableAutomaticChecks=true`, a `SUScheduledCheckInterval` (Cotypist uses a daily-ish interval), and a "Check for Updates…" menu item calling `SPUStandardUpdaterController.checkForUpdates(_:)`. Host the appcast + signed zip/DMG anywhere static.

---

## Cross-cutting notes for typer
- **Prompt assembly** is budget-allocated, not concatenated. `enum PSID { screenshot, environmentContext, previousUserInputs, pasteboard, … }`; `TBS`/`TBAL` are per-section token budgets (`maxBudget/minBudget/priority`, `isIncluded`). `PromptCoordinator.Context` carries `appProperties (bundleId, name, windowTitle, url, typingContext, osUsername)`, `textFieldProperties (placeholder, help, title, identifier, language…)`, `screenshotText/Image`, `previousUserInputs`, `pasteboardTokens`. typer can adopt a priority-budget allocator so screenshot/context degrade gracefully under a token cap rather than truncating blindly.
- **KV-cache prefix reuse** is explicit (`promptPrefix`, `prefixHasInstructions`, `GenerationManager.reuseThreshold`, `resetCompletionManagerDueToUserPromptChange`). typer should cache the tokenized instruction+template prefix and only invalidate when instructions/app change.
- `userDidVoteForSuggestion` is **support-chat (RepliesSDK)**, not autocomplete feedback — do not model a candidate-vote API on it.
