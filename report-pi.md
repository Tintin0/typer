REVIEWED BY CLAUDE CODE | APPROVED

# Adversarial review: efficiency + cleanup

Scope: reviewed the macOS app (`scripts/typer_native.swift`), GGUF helper (`scripts/llama_server.cpp`), install/build scripts, config, and web landing page. I did not implement fixes.

## Executive summary

Biggest opportunities are not micro-optimizations in llama.cpp; they are avoiding unnecessary work before inference starts. The app still loads/uses the model in states where users think completions are off, does repeated AX reads and synchronous logging while streaming partials, and allows speculative prefetches to occupy the single helper ahead of foreground requests.

`web` builds successfully, but Vite warns the landing bundle is `508.64 kB` minified because Three.js is statically imported.

## Findings

### 1. Turning completions off can still run the LLM

Evidence:
- `applicationDidFinishLaunching` always warms the helper: `scripts/typer_native.swift:618`.
- `generate()` does not check `completionEnabled` before selecting an LLM task: `scripts/typer_native.swift:1166`.
- `chooseTask()` returns `"typo"` when completions are disabled: `scripts/typer_native.swift:1690-1693`.
- The C++ helper has a separate LLM typo path: `scripts/llama_server.cpp:448-456`, while Swift already uses `NSSpellChecker` locally for typo correction.

Why it matters: users disabling completions, or running with only local typo correction, may still pay model startup and inference costs.

Recommendation: make `generate()` return early unless an LLM-backed feature is enabled. If typo correction is intended to be local-only, remove the C++ `typo` path and avoid helper warm-up when `completion_enabled=false` and `grammar_correction_enabled=false`.

### 2. Streaming partials likely over-read AX and over-log

Evidence:
- Each partial dispatches to main and calls `showCompletionRemainder(animate: true)`: `scripts/typer_native.swift:1203-1207`.
- `showCompletionRemainder()` defaults to re-anchoring: `scripts/typer_native.swift:1057`.
- Re-anchoring calls `currentCaretPoint()` / AX caret reads: `scripts/typer_native.swift:1577`, `1937`, `2023`.
- `log()` opens/seeks/writes/closes synchronously: `scripts/typer_native.swift:16-24`, and caret/AX code logs frequently.

Why it matters: a 10-token stream can trigger many AX calls plus synchronous file writes before the final suggestion. This eats the latency saved by streaming.

Recommendation: anchor only on the first partial, then update text at the cached point until final/reanchor. Coalesce partial UI updates to word boundaries or a small interval (e.g. 30-50 ms). Move high-frequency caret/AX logs behind `debugLogging` or write logs asynchronously/batched.

### 3. Speculative prefetch can block real requests

Evidence:
- `maybePrefetch()` starts a helper request on `backgroundQueue`: `scripts/typer_native.swift:1119-1131`.
- `MLXClient.request()` serializes all requests through one lock: `scripts/typer_native.swift:247`.
- Prefetch is not represented by `requestInFlight`, so a foreground generate can queue behind a stale speculative request.

Why it matters: prefetch is intended to reduce perceived latency, but with one helper process it can increase latency exactly when the user has new input.

Recommendation: treat prefetch as cancellable/low priority. Do not start it unless the helper is idle and no debounce is pending; abort/drop it as soon as foreground generation is needed. Consider a single `helperBusy` state or request priority queue around `MLXClient`.

### 4. Synchronous file I/O remains in hot paths

Evidence:
- Every `log()` call opens and closes the log file: `scripts/typer_native.swift:16-24`.
- `StyleMemory.sample()` reads `style.txt` synchronously: `scripts/typer_native.swift:464-465`.
- `assembledContext()` calls `styleMemory.sample()` for every generation/prefetch: `scripts/typer_native.swift:1677-1681`.

Why it matters: generation scheduling is latency-sensitive. Disk I/O on the main thread adds avoidable jitter.

Recommendation: keep style memory cached in RAM and refresh it on the existing style queue when records are appended/cleared. Make logging async, or keep one file handle open and gate verbose logs behind debug mode.

### 5. AX context reads are still broad

Evidence:
- `textAroundCursor()` copies the full `AXValue` up to 20k UTF-16 units on each generation: `scripts/typer_native.swift:1885-1908`.
- `windowText()` recursively walks the focused window AX tree: `scripts/typer_native.swift:1397-1431`.

Why it matters: AX can be slow or block on target apps. The app already falls back for huge fields, but even 20k copies per pause are expensive in editors and chat apps.

Recommendation: prefer range-based AX APIs where available (`AXSelectedTextRange` + string-for-range around the caret) instead of whole `AXValue`. Cache per-app/per-element capability failures. Back off `windowText()` more aggressively when immediate context is already sufficient.

### 6. Landing page ships Three.js up front

Evidence:
- `web/src/main.ts` statically imports `scene3d`.
- `npm run build` passes but reports `dist/assets/index-*.js` at `508.64 kB` minified with a Vite chunk warning.

Recommendation: lazy-load `scene3d` only when WebGL and non-reduced-motion are available. The command fallback/reduced-motion path should not download/parse Three.js.

## Cleanup candidates

- Remove unused Swift fields/methods: `acceptedWords`, `pendingTypoElement`, `pendingTypoRange`, `replacePreviousWord()`, `textBeforeCursor()`, `selectedOrWordRect()`, `testCompletion()`, `testTypo()`, `testGrammar()`.
- Remove or finish `grammar_correction_enabled`. Swift can choose `"grammar"`, but the C++ helper has no grammar branch, so it falls through to completion behavior.
- Rename `MLXClient`/`MLXRequest`/`MLXSuggestion`; the current backend is GGUF/llama.cpp, not MLX.
- Split the 2,181-line `typer_native.swift` into focused files: config, menu, event taps, generation client, overlay, AX/caret, context sources, typo, stats.
- Remove stale/unused C++ parameters such as `prompt_complete(..., max_words)` if not needed.
