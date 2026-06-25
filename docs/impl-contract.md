# typer Overhaul — Implementation Contract (AUTHORITATIVE over the spec on ownership)

Read this WITH `docs/overhaul-spec.md`. Where this contract and the spec disagree on **file
ownership or scope**, THIS FILE WINS. The spec's per-feature APIs/acceptance criteria still apply.

## Locked product decisions (from the human)
- **#4 inline-prediction:** ship GUIDE + an explicit opt-in one-click write button (record prior
  value for restore). NOT auto-write.
- **#5 multi-candidate picker:** DO NOT BUILD. It goes in a wishlist doc only (`docs/wishlist.md`).
  Skip Wave 3 entirely.
- **#6 Sparkle / auto-update:** DO NOT BUILD. Do **not** touch `build.sh` or `Info.plist` for
  updates. Leave the existing git-rebuild updater untouched.
- **#10 personalization / Wave 4:** interim **logit-bias map only** (from the user's high-frequency
  words). NO LoRA train/attach this round (personalization training is paused per project memory).
  DO still log the accept/reject signal to `training.jsonl`.
- **Denylist default:** password managers ALWAYS suppressed; IDEs/own-autocomplete apps suppressed
  by default but per-app overridable via `AppOverrides.completionsDisabled = false`.

## Build / compile gate (run after EVERY wave; the next wave starts only on green)
```
swiftc scripts/typer/*.swift -o /tmp/typer-check          # Swift app — primary gate (fast, no -O)
# Only if you changed scripts/llama_server.cpp, also build the helper:
bash scripts/build.sh                                      # full build (resolves llama.cpp, signs, restarts)
```
The Swift app links no llama libs (it spawns the C++ helper over a pipe), so the `swiftc` line is a
complete compile check for Swift-only changes.

## The Golden Rule
**No two agents in the SAME wave may edit the same existing file.** Waves run sequentially; a file
edited by an earlier wave and again by a later wave is fine. New files are owned by exactly one agent.

## Hot shared files — ownership across the whole overhaul
| File | Who edits it | Notes |
|---|---|---|
| `TyperConfig.swift` | **W0 ONLY** | every new config field for every feature, added once |
| `TyperApp.swift` | **W0** (stored props + launch call-sites), then **W1C** (denylist statics, secure-field check, `isAppDisabled` OR-in) | NO wave-2+ agent edits this file |
| `TyperApp+Menu.swift` | **W0** (setters + MenuAction stubs + menu scaffolding), then **W2A** (snooze content) | no other wave-2 agent touches it |
| `MenuPopover.swift` | **W0** then **W2A** | menu UI; same cluster as Menu |
| `OnboardingWindow.swift` | **W2D ONLY** | inline-prediction card |
| `SettingsWindow.swift` (NEW) | **W0** (shell + shared rows + open action), then **W2A** (content) | |
| `GhostView.swift`, `SuggestionOverlay.swift` | **W1A** (host font), then **W2D** (typo styling) | sequential |
| `TyperApp+Context.swift` | **W1B** (capture), then **W2B** (#1 per-app-instructions injection) | sequential |
| `LlamaClient.swift` | **W1B** (token cache), then **W2B** (FIM suffix) | sequential |
| `llama_server.cpp` | **W1B** (tokenize endpoint), then **W2B** (FIM) | sequential; rebuild via build.sh |
| `ModelRouter.swift` | **W2C** (#11 tiering), then **W4** (logit-bias) | sequential |
| `TyperApp+Completion.swift` | **W2B ONLY** in waves 1-2 (generate() guards: snooze/denylist/#13 midline/#9 length/#10 strength), then **W4** (bias pass) | |
| `TyperApp+Typo.swift` | **W2D ONLY** | emoji + typo gate |
| `TyperApp+AXObserver.swift` | **W1B ONLY** | deferred-release observer |
| `TyperApp+EventTap.swift` | **W1C ONLY** (secure gate) | |
| `TyperApp+Model.swift` | **W2C ONLY** | |

## New files and their sole owner
| New file | Owner | Purpose |
|---|---|---|
| `AppOverrides.swift` | **W0** (full impl — it's data) | per-app/per-domain quirk + customInstructions store (JSON sidecar) |
| `AXSafe.swift` | **W0** (full impl) | `axRead()` + `AXUIElementSetMessagingTimeout` 50 ms helpers (shared) |
| `Admissibility.swift` | **W0** (full impl) | inadmissibility backoff state + PW-manager/IDE denylist sets + `isAppDisabled` helpers (shared) |
| `LetsMove.swift` | **W0 stub** (`maybeOfferMoveToApplications()` no-op), **W2C** fills | move-to-/Applications |
| `CoordinateUtil.swift` | **W1A** | fold `axRectToAppKit` + screen-flip |
| `TextMirror.swift` | **W1A** | TextKit mirror caret rect overlay |
| `ScrollMonitor.swift` | **W1A** | scroll-wheel caret invalidation |
| `EmojiData.swift` (+ resources) | **W2D** | shortcode→emoji, skin tone, gender |
| `InlinePrediction.swift` | **W2D** | detect + deep-link + opt-in write (#4) |

## Wave 0 mandate (the enabler — must leave the tree COMPILING)
W0 creates every hot-shared-file change + every new shared/stub file so later waves only fill disjoint
files. After W0, `swiftc scripts/typer/*.swift -o /tmp/typer-check` MUST pass.
W0 deliverables:
1. `TyperConfig.swift`: add all new fields with sane defaults + TOML `load()` cases +
   `config.example.toml` rows. Fields (at least): `personalizationStrength: Double=0`,
   `maxCompletionWords` already exists (add segmented mapping later in W2A), `showSuggestedFixes: Bool`,
   `suppressCompletionOnTypoSuspected: Bool`, `emojiCompletionsEnabled: Bool`, `emojiSearchEnabled: Bool`,
   `emojiSkinTone: Int=0`, `midLineCompletionsEnabled: Bool=true`, `inlinePredictionWarn: Bool=true`,
   plus any feature flag the spec references.
2. `TyperApp.swift`: add stored props `allCompletionsDisabledUntil: Date?`,
   `perAppDisabledUntil: [String: Date]`, and method `completionsAllowed(bundle:) -> Bool`; add the
   `maybeOfferMoveToApplications()` call at the top of `applicationDidFinishLaunching`.
3. `AppOverrides.swift`, `AXSafe.swift`, `Admissibility.swift` — full implementations per spec D.5/D.1/
   C.5/D.3/D.4 (incl. the exact password-manager + IDE bundle-id sets from spec D.3/D.4).
4. `LetsMove.swift` — stub `extension TyperApp { func maybeOfferMoveToApplications() {} }`.
5. `SettingsWindow.swift` — window controller + SwiftUI host + shared `SliderRow`, `StepperRow`,
   `SegmentedRow` components; an empty sectioned body; a way to open it.
6. `TyperApp+Menu.swift`: add `setInt`/`setDouble`/`setString` siblings to `setToggle`; add new
   `MenuAction` cases (`openSettings`, `snooze(minutes:)`, `snoozeApp(minutes:)`, `resumeCompletions`)
   as stubs that compile; add an "Open Settings…" menu item that opens `SettingsWindow`.
Everything else (real logic) is filled by later waves into THEIR files.

## Adjusted wave list (Sparkle + picker removed)
- W0 Foundation (1 agent)
- W1: 1A Caret core · 1B Capture/stability core · 1C Stability/denylist (3 parallel)
- W2: 2A Settings content · 2B Completion semantics · 2C Model+LetsMove (NO Sparkle) · 2D Inline-pred+emoji+typo (4 parallel)
- W4 MLOps: accept/reject logging + logit-bias map (1 agent)  [no LoRA]
- Wishlist: write `docs/wishlist.md` capturing #5 multi-candidate picker + #6 Sparkle/notarized-DMG as deferred items (1 agent, parallel-safe)

## Every implementation agent MUST
- Read `docs/overhaul-spec.md` (your sections) + the named `docs/research/*.md` before editing.
- Edit ONLY your owned files (+ your new files). If you think you need another file, STOP and note it
  in your return summary instead of editing it.
- Match the spec's public APIs exactly so siblings integrate.
- Run `swiftc scripts/typer/*.swift -o /tmp/typer-check` before returning IF your changes are
  self-contained; otherwise note what a sibling must provide. Never leave obvious syntax errors.
- Return: files changed, new public APIs exposed, any deviation from spec, any cross-agent dependency.
