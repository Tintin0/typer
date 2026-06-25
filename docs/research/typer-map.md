# Typer implementation map — integration points + conflict matrix

Read-only survey of `/Users/jason/Code/typer/scripts/typer/*.swift` (+ `scripts/build.sh`,
`install.sh`, `update.sh`, `config.example.toml`). Goal: give the implementation fleet exact
files / functions / line ranges, current behavior, and the integration seam for each planned
feature, plus a file-ownership matrix so work can be parallelized safely.

Line ranges are as of this survey; treat them as anchors, not literals (re-grep before editing).

---

## 0. How the app is built / run (compile-to-verify)

- **Sources**: every `scripts/typer/*.swift` is compiled as ONE module by `swiftc`. There is no
  Xcode project, no SwiftPM manifest. New files just need to land in `scripts/typer/`.
- **Helper**: `scripts/llama_server.cpp` -> `~/.local/share/typer/typer-llama-server` (clang++,
  links Homebrew llama.cpp). Sampling (temp/top-k/min-p) lives here, not in Swift.
- **Build command (this is the verify step):**
  ```
  bash /Users/jason/Code/typer/scripts/build.sh
  ```
  It: builds the C++ helper, runs `swiftc -O scripts/typer/*.swift -o ~/.local/share/typer/typer-menu-bar`,
  copies it to `~/Applications/Typer.app/Contents/MacOS/Typer`, writes `Info.plist` (stamps
  `TyperRepoPath` + `TyperGitCommit` via PlistBuddy), codesigns (stable self-signed cert
  `Typer Self-Signed` if present, else ad-hoc), then `pkill`s the running app + helper.
- **Run**: `open ~/Applications/Typer.app`. Logs: `~/Library/Logs/Typer.log`.
- A pure compile check without install: `swiftc -O scripts/typer/*.swift -o /tmp/typer-check`
  (will fail to link only if a symbol is missing; AppKit/Vision/etc. are system frameworks).
- **No Sparkle, no Developer ID.** Self-update = rebuild-from-checkout via `update.sh` driven by
  `TyperApp+Menu.swift` (`checkForUpdates`). Codesigning is self-signed only.

### Config system (the central shared surface)
`TyperConfig.swift` is a flat `struct TyperConfig` (fields lines 10-104) + a hand-rolled TOML
parser `static func load()` (lines 106-167, a `switch` on `key`). Persistence is **per-key line
rewrite**, NOT re-serialization: `TyperApp.writeConfig(_:_:)` in `TyperApp+Menu.swift:179-192`.
Config lives at `~/Library/Application Support/typer/config.toml`. `config.example.toml` is the
documented template copied by `install.sh`.

**Adding a config field is a 3-edit pattern, every time:**
1. add `var fieldName = default` to the struct (TyperConfig.swift:10-104),
2. add a `case "field_name": cfg.fieldName = …` to the `load()` switch (TyperConfig.swift:116-163),
3. document it in `config.example.toml`.
String/Set fields need custom split logic (see `disabled_apps` at TyperConfig.swift:162).

### Menu construction
SwiftUI popover, not NSMenu. `TyperApp+Menu.swift:setupMenu()` (12-27) hosts `MenuRootView`
(MenuPopover.swift:84-265). State flows: `menuSnapshot()` (TyperApp+Menu.swift:67-121) builds a
`MenuSnapshot` struct (MenuPopover.swift:19-61) -> rendered by `MenuRootView` -> toggles call
`MenuModel.bind` -> `setToggle(key:on:)` (TyperApp+Menu.swift:125-154) -> `writeConfig`. Actions
route through `MenuAction` enum (MenuPopover.swift:63-65) -> `performMenuAction` (158-171).
**Every new menu toggle touches: MenuSnapshot field + menuSnapshot() assignment + setToggle()
case + a SwitchRow in MenuPopover.swift.** Every new action: MenuAction case + performMenuAction
case + ActionRow.

### Completion pipeline
`TyperApp+EventTap.swift` (taps) -> `handleTyping` (250-306) -> `scheduleGenerate`/`generate`
(TyperApp+Completion.swift:305-404) -> `LlamaClient.request` (LlamaClient.swift:100-134, streaming
JSON over a pipe to the helper) -> `presentCompletion` (TyperApp+Completion.swift:409-468) ->
`showCompletionRemainder` (165-170) -> `SuggestionOverlay.showCompletion`. Accept: `acceptCompletionWord`
(Tab, 210-237) / `acceptCompletionAll` (backtick, 240-254). Routing through `ModelRouter.pick()`.
`ActiveCompletion` (chars + consumed cursor) is the in-flight suggestion type.

### Caret / context / overlay / models — see per-feature rows below.

---

## 1. Per-app custom instructions
- **Touch**: `TyperConfig.swift` (new field, e.g. `var appInstructions: [String:String] = [:]`,
  parse in load() ~line 162 like `disabled_apps`); `TyperApp+Context.swift:assembledContext(immediate:)`
  (336-370) to inject the instruction block; `TyperApp+Menu.swift` (a menu row to edit per-app
  text) + `MenuPopover.swift` (UI). Persistence via `writeConfig` (serialize the dict to one line)
  or a sidecar JSON.
- **Current**: no per-app instruction concept. `assembledContext` already keys behavior off
  `currentAppBundleAndName().name` (adds "Writing app: X" at line 339) and `appCategory()`
  (TyperApp.swift:215-228). Disabled-apps set is the existing per-bundle config precedent.
- **Seam**: insert a labeled block in `assembledContext` keyed on `currentAppBundleAndName().bundle`.
  The prompt is already block-structured (blocks joined by `\n\n`), so add a block before
  `blocks.append(immediate)` at line 368.

## 2. Password-manager / secure-field denylist default
- **Touch**: `TyperApp.swift:terminalBundleIDs` (206-210) as the precedent for a static Set; add a
  static `sensitiveAppBundles` (it ALREADY EXISTS as `TrainingLog.sensitiveAppBundles`, referenced
  in `TyperApp+Completion.swift:91` — promote/reuse it). Gate in `generate()`
  (TyperApp+Completion.swift:318-323) and/or `isAppDisabled()` (TyperApp.swift:253-258).
- **Current**: secure input is already fully handled: `IsSecureEventInputEnabled()` short-circuits
  the observer (TyperApp+EventTap.swift:146-149) and training capture (`canCaptureTraining`
  TyperApp+Completion.swift:88-94). Clipboard concealed/transient types are skipped
  (TyperApp+Context.swift:67-69). But there is **no default denylist of password-manager bundle IDs
  for the COMPLETION path** — only for training capture.
- **Seam**: add the password-manager bundle Set (1Password `com.1password.1password`, `com.agilebits.onepassword*`,
  Bitwarden `com.bitwarden.desktop`, KeePassXC `org.keepassxc.keepassxc`, etc.) and OR it into
  `isAppDisabled()` (TyperApp.swift:253) — that's the single chokepoint `generate()` already calls.

## 3. Timed snooze
- **Touch**: `TyperApp.swift` (new `var snoozeUntil: Date?` instance state near line 81 next to
  `acceptGraceUntil`); `generate()` guard (TyperApp+Completion.swift:323); `TyperApp+Menu.swift`
  (MenuAction + handler) + `MenuPopover.swift` (header/footer control + countdown). Status title in
  `updateStatusTitle()` (TyperApp+Menu.swift:32-41).
- **Current**: only a permanent `cfg.enabled` toggle (header switch MenuPopover.swift:126-139,
  `setToggle "enabled"`). No timed pause. `acceptGraceUntil` (TyperApp.swift:81) is the existing
  "Date < X" gating idiom to copy.
- **Seam**: add `Date() < snoozeUntil` check to the `cfg.enabled` guard in `generate()` and to
  `updateStatusTitle()` (show "⏸ 14m"). A `Timer` re-fires `updateStatusTitle` to count down.
  Does NOT need a config field (snooze is ephemeral).

## 4. Disable macOS inline prediction
- **Touch**: NEW concern; nothing exists. Best home is a one-shot at launch in
  `TyperApp.swift:applicationDidFinishLaunching` (152-185) plus a note in onboarding.
- **Current**: not handled at all. Typer's ghost can collide visually with macOS's own inline
  predictive text (the system feature on `NSTextInputContext`).
- **Seam (best-practice, opaque in Typer)**: Typer cannot disable the system setting per-app from
  outside. Two real options: (a) write the user default
  `NSAutomaticInlinePredictionEnabled = false` in Typer's OWN domain (only affects Typer's text
  fields — not useful), or (b) detect and document. The implementable path is to set
  `defaults write -g NSAutomaticInlinePredictionEnabled -bool false` guidance in onboarding
  (`OnboardingWindow.swift` howto step, lines 189-203) OR, for fields Typer controls, call
  `someTextView.isAutomaticTextCompletionEnabled = false`. Since Typer never owns the host text
  view, this is primarily an onboarding/doc + optional global default toggle in `TyperConfig`.

## 5. Multi-candidate picker
- **Touch**: `LlamaClient.swift:request` (100-134) + `HelperSuggestion`/`StreamLine` wire types
  (defined in `HelperProtocol.swift`) to return N candidates; `scripts/llama_server.cpp` to emit
  them; `ActiveCompletion` (TyperApp.swift uses it; struct likely in HelperProtocol/TyperApp) to
  hold alternates; `SuggestionOverlay.swift` + `GhostView.swift` for the picker UI;
  `TyperApp+EventTap.swift:accept` (213-245) to bind cycle keys (e.g. Option-Tab).
- **Current**: single candidate only. Streaming returns ONE `text` per generation. Overlay
  (`SuggestionOverlay.place`, lines 61-82) renders one ghost line. The accept tap handles only
  Tab (word) / backtick (all). No alternates concept anywhere.
- **Seam**: this is the deepest feature — touches the helper protocol, the helper C++, the overlay,
  AND the keymap. Highest conflict surface. Recommend: helper returns top-k; store
  `[ActiveCompletion]` + selected index on TyperApp; add a cycle key in `accept`; render the
  selected one through the existing `showCompletionRemainder`.

## 6. Sparkle auto-update
- **Touch**: replaces the home-grown updater in `TyperApp+Menu.swift:269-390` (`checkForUpdates`,
  `promptInstallUpdate`, `startUpdate`, `runUpdateScript`, `updateAlert`); `scripts/build.sh`
  (bundle a Sparkle.framework + Info.plist `SUFeedURL`/`SUPublicEDKey` keys, lines 53-77);
  `MenuPopover.swift:249-251` (the existing "Check for updates" IconButton, gated on `s.canUpdate`).
- **Current**: NO Sparkle. Self-update = `update.sh` git fast-forward + `build.sh` rebuild, only for
  source builds that stamped `TyperRepoPath` into Info.plist (build.sh:75-77; gated by `canUpdate`
  in `menuSnapshot` lines 113-117). Closed-binary distribution can't use this.
- **Seam (best-practice)**: add SPM/`Sparkle.framework` to `build.sh`, set `SUFeedURL` +
  `SUPublicEDKey` in Info.plist, instantiate `SPUStandardUpdaterController` at launch
  (`applicationDidFinishLaunching`), and point the menu's check button at
  `updater.checkForUpdates()`. Requires a signed appcast + EdDSA key. Keep the git path as the
  source-build fallback. **Conflict with #15 and #11** if those also edit Info.plist/build.sh.

## 7. Emoji completion
- **Touch**: `TyperApp+Typo.swift` (parallel to `correction(for:)` at 57-91 — add an emoji lookup
  on `:shortcode`); `TyperApp+EventTap.swift:handleTyping` (250-306, detect `:name:` pattern);
  `Correction.swift` (could reuse the `.spelling`-style diff, or a new kind);
  `SuggestionOverlay.show(correction:)` (39-57) for rendering.
- **Current**: none. Typo correction uses `NSSpellChecker` only. No emoji map.
- **Seam**: simplest as a new branch in `handleTyping` that, on detecting a completed `:smile:`-style
  token, presents an emoji via the EXISTING `Correction` machinery (it's already span/length-based,
  Correction.swift:9-19). Or feed the LLM — but a static shortcode map is cheaper and deterministic.
  Touches the typo file (shared with #8).

## 8. Suggested-fix styling + typo-suspicion gate
- **Touch**: `SuggestionOverlay.swift:show(correction:)` (39-57, the red-strike→green-replacement
  styling — already exists); `TyperApp+Typo.swift:correction(for:)` (57-91, the suspicion gate
  already partly exists via `typoMinConfidence`/`rankGuesses`); `TyperConfig.swift` for any new
  knob; `GhostView.swift` if styling needs more than attributed-string changes.
- **Current**: ALREADY substantially built. `show(correction:)` renders strikethrough-red original
  + green replacement (SuggestionOverlay.swift:42-49); advisory grammar renders amber (50-55). The
  suspicion gate exists: `typoMinConfidence` normalized-edit-distance reject (TyperApp+Typo.swift:84-89),
  `rankGuesses` (97-108), QWERTY-neighbor bonus (112-122). Defaults are conservative (ranking OFF).
- **Seam**: mostly a tuning/default-flip + styling-polish task, not new architecture. Flip
  `typoRankingEnabled`/`typoCasingFix` defaults in TyperConfig.swift:20-22, and refine the
  attributes in `show(correction:)`. Low risk, isolated to Typo + Overlay.

## 9. User-facing completion length control
- **Touch**: `TyperConfig.swift:maxCompletionWords` (line 25, already exists); `MenuPopover.swift`
  (new picker/stepper row — there is NO slider component yet); `TyperApp+Menu.swift`
  (MenuSnapshot field + menuSnapshot + a `setToggle`-equivalent for an Int, OR a new setter).
- **Current**: `maxCompletionWords` (default 7) is config-only — no UI. It's consumed via
  `trainingMaxWords`/`adjustedMaxWords` in `generate()` (TyperApp+Completion.swift:361) and
  `maybePrefetch` (269). Adaptive layer (`feedback.adjustedMaxWords`) already modulates it.
- **Seam**: add a segmented/stepper control to the menu. `setToggle` only handles Bools, so add a
  sibling `setMaxWords(_ n: Int)` in TyperApp+Menu.swift that calls `writeConfig("max_completion_words", String(n))`
  and updates `cfg`. New UI component needed in MenuPopover.swift (model after `ModelSizePicker`
  lines 345-370).

## 10. Personalization strength slider
- **Touch**: `TyperConfig.swift` (new `var personalizationStrength: Double`);
  `TyperApp+Context.swift:assembledContext` (353-367, where style sample chars are chosen) +
  `lexicon.topWords()` calls in `generate()`/`maybePrefetch` (TyperApp+Completion.swift:269,362);
  `MenuPopover.swift` (slider UI — none exists); `TyperApp+Menu.swift` (setter).
- **Current**: personalization is BINARY toggles only: `styleMemoryEnabled`, `lexiconEnabled`,
  `adaptiveSuggestions` (TyperConfig.swift:43-44, 40). The style sample size is a fixed 360/160-char
  branch (TyperApp+Context.swift:359). No continuous strength.
- **Seam**: scale `maxChars` in `assembledContext` (line 359) and lexicon `topWords()` count by a
  0..1 strength. Needs a real slider component (none in MenuPopover.swift today — same gap as #9).
  Shares the style/lexicon plumbing with several context features.

## 11. Polished model catalog + disk-space pre-check
- **Touch**: `ModelRouter.swift:downloadTiers` (43-50, the catalog) + `ModelTier` struct (36-50);
  `ModelDownloader.swift` (add a free-space check before `download`, lines 28-34);
  `TyperApp+Model.swift:setModelVariant` (46-64, where the download is kicked off);
  `OnboardingWindow.swift:modelChoice` (160-186) + `MenuPopover.swift:modelSection` (144-175) for UI.
- **Current**: catalog is the 2-entry `downloadTiers` array (m=1834MB, l=4366MB) with size hints
  already present. Download validates GGUF magic + size>100MB (ModelDownloader.swift:54-66) but does
  **NOT pre-check free disk space**. UI shows progress + size labels already
  (OnboardingWindow.swift:167-184, MenuPopover.swift:152-168).
- **Seam**: add a `volumeAvailableCapacityForImportantUsage` check in `setModelVariant`
  (TyperApp+Model.swift:51, before `ModelDownloader.shared.download`) using `approxMB`; surface an
  alert if short. Catalog "polish" = extend `downloadTiers` + the label strings. Isolated to the
  model files; light overlap with onboarding (#14 is separate; #12 separate).

## 12. Let's Move (offer to move app to /Applications)
- **Touch**: NEW; nothing exists. Home: `TyperApp.swift:applicationDidFinishLaunching` (152-185,
  early, before onboarding at 173). `build.sh` installs to `~/Applications/Typer.app` (build.sh:14).
- **Current**: not handled. App is built to `~/Applications`, not `/Applications`.
- **Seam (best-practice)**: bundle/port the LetsMove `PFMoveApplication()` routine (or reimplement:
  detect `Bundle.main.bundlePath` not under `/Applications`, offer to copy via `NSWorkspace`/
  `FileManager`, relaunch). Call once at the top of `applicationDidFinishLaunching`. Standalone —
  only conflicts with #3/#6 if they also add launch-time code (same function, serialize).

## 13. Mid-line completion fidelity
- **Touch**: `TyperApp+Context.swift:isMidLine(after:)` (186-192) + `textAroundCursor` (155-181);
  `TyperApp+Completion.swift:generate()` (the mid-line skip at 344-346) and the trailing-repeat
  drop in `presentCompletion` (433-437).
- **Current**: mid-line is currently SUPPRESSED, not completed. `isMidLine` returns true if any
  non-whitespace remains on the line after the caret, and `generate()` bails (line 345). There's
  also a trailing-text-repeat guard (presentCompletion:434). So "fidelity" = make it actually
  complete mid-line correctly instead of staying silent.
- **Seam**: relax `isMidLine` (e.g. allow completion when the caret is at a word boundary mid-line,
  or pass `after` text to the helper so it completes *into* context). Requires the prompt to carry
  `after` (currently `axCtx.after` is only used for suppression + repeat-drop, TyperApp+Completion.swift:349).
  Helper-side (`llama_server.cpp`) may need a fill-in-the-middle prompt format. Touches the context
  + completion files (both shared with #1, #10).

## 14. Google Docs accessibility flow
- **Touch**: `TyperApp+Caret.swift` (caret reads: `caretPoint` 205-233, `textMarkerCaretRect`
  238-255, `boundsForSelectedRange` 307-372); `TyperApp+Context.swift:textAroundCursor` (155-181)
  + `windowText` (15-49); possibly `caretPathByBundle` (TyperApp.swift:47).
- **Current**: Google Docs renders to a canvas; its text is exposed only when Chrome/Docs
  "screen-reader/accessibility mode" is on. Typer has NO Docs-specific handling. The AX caret paths
  (text-marker preferred for Chromium, line 218-224) and the 20000-char AXValue cap
  (TyperApp+Context.swift:163) are the relevant generic machinery; the screenshot-caret fallback
  (TyperApp+Caret.swift:98-135) and click-anchor (45-58) are the AX-hostile fallbacks Docs would hit.
- **Seam (best-practice)**: detect docs.google.com (window title / URL via AX), and (a) prompt the
  user to enable Docs accessibility (Tools > Accessibility / Cmd-Option-Z), (b) lean on the
  click-anchor + screenshot caret since the canvas exposes no AX caret. Likely add a Docs branch in
  `caretPoint`/`textAroundCursor`. Conflicts with #13 (both edit caret/context).

## 15. Privacy / settings panes
- **Touch**: `MenuPopover.swift` (the entire settings UI lives here — sections at 210-243,
  footer 245-262); `OnboardingWindow.swift` (permissions step 143-157, privacy copy);
  `TyperApp+Menu.swift` (the actions: `openConfig`, `resetData`, `confirmTrainingCapture`,
  `openTrainingData`, lines 194-251). NO dedicated Settings WINDOW exists.
- **Current**: "settings" = the SwiftUI popover (MenuPopover.swift) + raw `config.toml` opened in a
  text editor (`openConfig`, TyperApp+Menu.swift:194). Privacy surface = the training-capture
  consent alert (`confirmTrainingCapture` 206-218), the "Reset All Data" alert (229-251), and the
  onboarding permissions step. There is no standalone Preferences `NSWindow`.
- **Seam**: a real pane = a new `SettingsWindow.swift` (model after `OnboardingWindow.swift`'s
  controller+SwiftUI-host pattern, lines 61-102) presented from a new MenuAction. It would READ/WRITE
  the same `cfg` + `writeConfig`. **This is the highest-conflict feature**: a settings pane is the
  natural home for #3, #9, #10 controls — coordinate so they land in the new pane, not the popover.

---

## FILE-OWNERSHIP / CONFLICT MATRIX

Legend: ●=primary owner / heavy edits, ○=light/append-only edit, blank=untouched.
Shared hot files are the columns most likely to cause merge conflicts.

| Feature \ File | TyperConfig.swift | TyperApp+Menu.swift | MenuPopover.swift | TyperApp+Completion.swift | TyperApp+Context.swift | TyperApp+Caret.swift | TyperApp+EventTap.swift | TyperApp+Typo.swift | OnboardingWindow.swift | ModelRouter.swift | ModelDownloader.swift | TyperApp+Model.swift | SuggestionOverlay/GhostView | LlamaClient + llama_server.cpp | build.sh / Info.plist | TyperApp.swift |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 Per-app instructions | ○ | ○ | ○ | | ● | | | | | | | | | | | |
| 2 PW-manager denylist | ○ | | | ○ | | | | | | | | | | | | ● |
| 3 Timed snooze | | ● | ○ | ○ | | | | | | | | | | | | ● |
| 4 Disable macOS inline pred | ○ | | | | | | | | ○ | | | | | | | ○ |
| 5 Multi-candidate picker | | | ○ | ● | | | ● | | | | | | ● | ● | | ○ |
| 6 Sparkle | | ● | ○ | | | | | | | | | | | | ● | ○ |
| 7 Emoji completion | | | | | | | ● | ● | | | | | ○ | | | |
| 8 Suggested-fix styling+gate | ○ | | | | | | | ● | | | | | ● | | | |
| 9 Completion length control | ○ | ● | ● | ○ | | | | | | | | | | | | |
| 10 Personalization strength | ○ | ● | ● | ○ | ● | | | | | | | | | | | |
| 11 Model catalog + disk check | | | ○ | | | | | | ○ | ● | ● | ● | | | | |
| 12 Let's Move | | | | | | | | | | | | | | | ○ | ● |
| 13 Mid-line fidelity | | | | ● | ● | | | | | | | | | ○ | | |
| 14 Google Docs AX | | | | ○ | ● | ● | | | ○ | | | | | | | ○ |
| 15 Privacy/settings pane | ○ | ● | ● | | | | | | ○ | | | | | | | ○ |

### Read-this-first: the four shared chokepoints
- **`TyperConfig.swift`** (struct lines 10-104 + load() switch 116-163): touched by 1,2,3?,4,8,9,10,15.
  Edits are append-only (new field + new case) and almost never collide IF each PR adds its field at
  the END of the struct and its case in a distinct spot. **Serialize only if two PRs edit the same
  region**; otherwise parallel-safe. Always mirror into `config.example.toml`.
- **`TyperApp+Menu.swift`** (`MenuSnapshot` assignment 67-121, `setToggle` 125-154, `performMenuAction`
  158-171): touched by 3,6,9,10,11,15. `setToggle` only does Bools — Int/Double/String settings need
  NEW sibling setters (don't overload the switch). **HIGH collision** on the switch statements.
- **`MenuPopover.swift`** (`MenuSnapshot` struct 19-61, `sections` 210-243, components 267-395):
  touched by 1,3,5,6,9,10,11,15. There is **no slider/stepper component yet** — #9 and #10 both need
  one; build it ONCE and share. **HIGH collision** on the `sections` ViewBuilder.
- **`TyperApp+Completion.swift`** (`generate()` 318-404, `presentCompletion` 409-468): touched by
  2,3,5,9,10,13. The `generate()` guard prologue (318-352) is where 2/3 add bail conditions and 13
  removes the mid-line skip. **Serialize 2+3+13** (all edit the same guard block).

### Parallelization recommendation
- **Run in parallel (low/no shared-file overlap)**: 6 (Sparkle), 7 (emoji), 8 (typo styling),
  11 (model catalog), 12 (Let's Move). Each is contained to its own files.
- **Serialize / single-owner the menu+config cluster**: 3, 9, 10, 15 all fight over
  `TyperApp+Menu.swift` + `MenuPopover.swift`. Best: build the **settings pane (#15) FIRST** as the
  container, then land 3/9/10 inside it. Build the shared slider/stepper component as part of #15.
- **Serialize the completion-guard cluster**: 2, 3, 13 all edit `generate()`'s prologue — one PR or
  ordered.
- **Serialize the caret/context cluster**: 13 + 14 both edit `TyperApp+Caret.swift` /
  `TyperApp+Context.swift` (`isMidLine`, `textAroundCursor`, caret reads).
- **Coordinate Info.plist/build.sh**: 6 and 11 (and 12) all may edit `build.sh`/Info.plist — keep
  the Info.plist block (build.sh:53-77) edits in one PR.

### Where state persists (so resets/clears stay correct)
- `config.toml` (settings) — written line-by-line by `writeConfig`.
- `~/Library/Application Support/typer/`: `router.json` (RouterMemory, 0600), `style.txt`
  (StyleMemory), `training.jsonl` (TrainingLog), lexicon/feedback/topic stores, `Models/` (GGUFs),
  stats. `resetData()` (TyperApp+Menu.swift:229-251) is the single clear-everything path — any new
  persistent store MUST be added there.
