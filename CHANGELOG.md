# Changelog

Typer is in **alpha** and not yet versioned. Entries are newest-first, led by the
commit they landed in. Website: [typr.frgmt.xyz](https://typr.frgmt.xyz).

## topic memory — resurface what you were just reading

A new opt-in context source. Every few minutes Typer OCRs the focused window (Apple
Vision, on the Neural Engine — no extra model), distills the **salient topics** (named
entities + repeated content nouns) and a short snippet via Apple's NaturalLanguage, and
stores them locally. Later, when you start typing and mention one of those things, the
snippet is folded into the prompt so it can help you recall it — e.g. read a product
page, then tell a friend "those Sony headphones I saw…" and the details resurface.

- **Distilled, not dumped.** It stores entities + a 1–2 sentence note, never the raw
  screen text, and only injects it **when a distinctive keyword you read is actually in
  what you're typing** (no influence otherwise).
- **Cheap + private.** Capture is periodic (`topic_capture_seconds`, default 180, min
  60), single-flighted, skipped on battery-saver, during secure input, in disabled
  apps, and in **terminals** (noisy/sensitive). On-device; `topics.json` is `0600`;
  cleared by Reset All Data. **Off by default** (needs Screen Recording). Toggle:
  menu → Context sources → "Remember what I read".

## site — lazy-load Three.js on the landing page

- `scene3d` (Three.js) is now a dynamic `import()` gated on WebGL + non-reduced-motion,
  so the **initial JS bundle dropped from ~508 kB to ~3.7 kB**. The 505 kB scene chunk
  is fetched only when the animation can actually run; reduced-motion / no-WebGL
  visitors get just the command, no Three.js download.

## 6e85d46 — helper: cheaper per-token shaping + sampler setup

- `make_sampler` accepts only the last 64 prompt tokens (the penalties window) instead
  of replaying the whole ~1024-token prompt through `accept()` every request.
- The streaming callback runs `first_line_clean` once per token and skips the
  O(context) `remove_echo` back-off scan on partials — only the final result de-echoes.
- Dropped the unused `max_words` parameter from `prompt_complete`, and deleted the
  dead LLM typo path (`prompt_typo`/`last_word`/task routing); typo correction is local
  (`NSSpellChecker`), so the helper now only ever does completion.

## 71a919d — prefetch yields the helper; no warmup when completions off

- `LlamaClient.request` gained a `lowPriority` (try-lock) mode: a speculative prefetch
  is skipped rather than queued if a foreground request holds the single helper, so it
  can never delay real input.
- The model isn't warmed at launch unless inline completion is enabled.

## f59e3da — remove hot-path disk + logging I/O

- `StyleMemory` keeps an in-RAM mirror, so `style.txt` is no longer read from disk on
  every generation/prefetch (it was a synchronous main-thread read up to 40KB).
- `log()` writes through one long-lived `FileHandle` on a serial queue instead of
  open→seek→write→close per call; per-keystroke caret/AX diagnostics are now `dlog`
  (gated off by default). These ran several times per keystroke on the main thread.
- Streaming partials re-anchor (an AX caret read) only on the first frame, not per
  token. The AX paragraph back-scan is capped at 40 (was 400) synchronous IPC calls.
- Dropped a redundant `rebuildMenu()` from the typo show/accept path.

## 5802e3e — cleanup: dead code, redundant modifier tracking, half-baked grammar

- Deleted 7 unused functions (`focusedWindowBounds`, `replacePreviousWord`,
  `selectedOrWordRect`, `textBeforeCursor`, the 3 `test*` stubs) and write-only fields
  (`generationSerial`, `shift`, `acceptedWords`, `pendingTypoElement/Range`).
- Dropped `keyUp` interest + `setModifier` and the Shift/Cmd/Ctrl/Opt booleans; the
  keyDown's `event.flags` already carries modifier state, so the observer tap no longer
  wakes on key *release* (≈half the observer callbacks).
- Removed the half-implemented grammar feature (the helper never had a grammar branch)
  and the LLM typo routing — completions-off now never invokes the helper at all.
- Renamed `MLXClient`/`MLXRequest`/`MLXSuggestion` (the backend is GGUF/llama.cpp).
- Net: ~120 fewer lines, no behavior change to the completion path.

## 3d12cb3 — menu-bar badge: keyboard SF Symbol + count

A text-only `NSStatusItem` can lay out to zero width and render invisibly — the item
was present but unseeable in the bar. The button now carries an SF Symbol image
(`keyboard`, template) with `imagePosition = .imageLeading` and the accepted count as
the title (`⏸` when paused). The image is set once (guarded on `button.image == nil`);
`updateStatusTitle()` only mutates the title thereafter.

## 5eb1393 — battery: kill accept-tap mach spin; screenshot-OCR caret off by default

Sampling the idle process showed ~60% CPU in `accept() → SLEventTapEnable →
_CGSEnableEventTap → mach_msg` — a blocking WindowServer round-trip fired in a loop.
This, not the model, was the drain.

- The consuming accept tap (`.defaultTap`, Tab/backtick) was re-enabled on every
  `tapDisabledByTimeout`/`ByUserInput` notification, including while nothing was
  showing — where our own `tapEnable(false)` echoes back as a disable and we re-enable,
  spinning. Tap state is now mirrored in `acceptTapEnabled`; `refreshAcceptTap()`
  early-returns when the desired state already holds, and the disabled-notification
  branch only re-arms when `completion`/`active != nil`. **Idle CPU 60% → 0%.**
- The screenshot+OCR caret locator (ScreenCaptureKit capture + `VNRecognizeTextRequest`,
  ANE-backed) ran on a ~1.2s / 6-char cadence for apps with no AX caret (terminals,
  custom editors) — far too hot to run continuously. Gated behind new
  `screenshot_caret_enabled` (default false) + menu toggle; recompute throttle loosened
  to 4s / 24 chars when enabled. AX/text-marker apps are unaffected.

## 9c3e0db — battery: pause-based debounce, battery-saver, chunked helper reads

- `debounce_ms` default 25 → 110. 25ms is shorter than inter-keystroke gaps
  (~80–200ms), so the trailing-debounce timer expired *between* keys and fired a full
  inference per character. 110ms coalesces a typing burst into one generation per pause.
- `PowerState`: IOKit `IOPSGetTimeRemainingEstimate()` vs `kIOPSTimeRemainingUnlimited`
  (cached 5s) OR `isLowPowerModeEnabled`. When `battery_saver` (default on) and on
  battery/LPM, debounce → `battery_debounce_ms` (300) and speculative prefetch is
  disabled (it runs a second inference per chunk, ~2× GPU work). Menu toggle shows
  "(throttling now)". Background-context refresh interval stretched to ≥10s while saving.
- Helper response reader replaced byte-at-a-time `poll`+`read` (≈2 syscalls/char) with
  4KB chunked reads + a leftover buffer split on `\n`. macOS energy impact is
  wakeup-dominated, so this cuts overhead during streaming.

## e3ea965 / d101a30 — overlay: Core Animation renderer + ghost-overlap re-anchor

- `GhostView` rewritten on Core Animation: `CATextLayer` in SF system font sized to the
  caret line, a trailing taper (`CAGradientLayer` root mask over the last ~20px), a
  one-shot shimmer (`CAGradientLayer` masked by a text layer, animated `locations`) and
  a fade-in (opacity + `transform.translation.y`) on fresh appearance only — not while
  typing through.
- Ghost no longer lags/overlaps typed text. The CGEvent tap runs *before* the host app
  applies the key, so a synchronous AX caret read is one step stale. The overlay now
  shifts by the measured width of what was typed immediately, then a coalesced
  `scheduleReanchor()` (0.05s) re-reads the true caret to correct drift/line-wrap.

## e824e3b / 0d69e29 / 15e8728 — event-tap rearchitecture, per-app disable, fast-Tab fix

- Two taps (cotabby-inspired): a **listen-only** observer at the head (cannot gate
  global input delivery) that builds buffer/state, plus a **consuming** accept tap at
  the tail, enabled only while a suggestion shows. Typer consumes no keys otherwise.
- Fast-Tab skipped-word fix: injected insertion events are tagged via
  `eventSourceUserData = syntheticMarker` and ignored by exact marker, replacing a
  count/timing guard that raced real keystrokes.
- Per-app disable (`disabled_apps`) + terminal skip (`disable_in_terminals`,
  `terminalBundleIDs`). Clipboard relevance filter (a long clip needs a shared word with
  the current context). Menu → Reset All Data… (NSAlert confirm) wipes style + stats,
  keeps config.

## 694dfc0 / 7423560 — clipboard-free insertion + drift/staleness fixes

- Accept inserts via a synthesized Unicode keystroke (`keyboardSetUnicodeString`), no
  pasteboard, with a self-suppression marker so it isn't re-processed as typing. The
  pasteboard path remains only for the off-by-default typo fallback.
- Ghost re-anchors at word boundaries (handles wrap), shifts by measured width within a
  word. Staleness matches on a trailing anchor (`suffix(80)`) so it survives the
  4000-char buffer cap and idle reset. `isMidLine(after:)` suppresses when any
  non-whitespace follows the caret on the line. Helper clears its KV cache on context
  front-truncation. `captureFocusedWindow` result race fixed (CaptureBox; frontPID
  snapshotted on main). Dead config knobs removed.

## 5885999 — security + robustness hardening (adversarial review)

Security & privacy:
- Never capture during macOS secure input (password fields, login window, `sudo`,
  password managers): no buffer, learning, logging, AX reads, or generation.
- Logs gated behind `debug_logging` (default off); log + `style.txt` are `0600`.
- Clipboard context skips concealed/transient items.
- `install.sh`: optional `TYPER_MODEL_SHA256`; reject path separators in the model
  filename. `build.sh`: safe array globbing for dylibs.

Robustness / concurrency:
- Event tap self-heals on `tapDisabledByTimeout`/`ByUserInput`.
- Off-main data race fixed — screenshot-caret + background closures snapshot
  buffer/config on the main thread.
- Helper reads time out (8s) and tear down a hung process so the next request respawns;
  warm-up is lock-safe; in-flight flags reset on all paths.
- Pasteboard serialized, restores all item types, guards `changeCount`.

Helper (C++): UTF-8-safe streaming partials, RAII sampler, `max_words` clamped.
Stats: honest accept-rate (promoted prefetches count as shown; per-keystroke "ignored"
counter removed).

## a7a7cf8 / 334cbdf / 37bfddb — sampling/anti-flicker, HTML strip, badge, fun stats

- `min-p` sampler (~6% of top-token prob) + lower temp/top-p; sampling settles at temp
  0.12, top-k 20, top-p 0.80, min-p 0.06, penalty 1.05. Far less random-word drift.
- Typing-through advances by measured char width instead of re-reading the jittery AX
  caret per key; panel stops re-ordering each update. Per-field caret-height floor
  prevents oversized ghost. Completions repeating post-caret text are dropped.
- `strip_html_tags` removes stray `<em>`/`</strong>` (keeps the `<` in `a < b`).
- Menu-bar badge `t|N` accepted count (live; `⏸` when paused) — later replaced by the
  icon badge (3d12cb3).
- Local stats: words/chars completed, daily streak / active days; playful scaling
  comparisons (Hobbit/LOTR/Harry Potter) and estimated time saved.

## ac27448 / e1d868d / 89430ab / 2aa3b65 / a51c917 — foundational alpha

Suggestion quality:
- Root cause: the helper never prepended Gemma's `<bos>` (tokenized with
  `add_special=false`), so the base model produced degenerate, repetitive output.
  `prompt_complete` now prepends `<bos>`. Confirmed the GGUF reports
  `chat_template=(null)` (a base model) → raw continuation is the correct strategy.
- Initial sampling tune (temp 0.65→0.20, top-k 40→20, top-p 0.92→0.90, penalty
  1.12→1.08). Preserve the model's spacing intent (a leading-space token means "new
  word") to fix `"autocompl ition"` / `"cool !"`. Suppress mid-word continuations the
  small base model gets wrong.

Caret & overlay:
- AX→AppKit coordinate flip uses the primary (zero-origin) screen height (multi-monitor
  fix).
- `isPlausibleCaretRect` validation + fallthrough: selection → zero-length caret → prev
  glyph → next glyph → paragraph scan.
- `AXTextMarker` caret (`AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`) for
  Chromium/WebKit (Discord/VS Code/Chrome/Safari) — exact caret, no screenshot.
- Screenshot+OCR locator (ScreenCaptureKit + Vision) as last resort; cached +
  extrapolated. (`CGWindowListCreateImage` is unavailable in the macOS 26 SDK.)
- Inline render: font sized to the caret line height, vertically centered; applies to
  completions, typo, grammar.

Speed & ergonomics:
- Follow-along: matching keystrokes consume the ghost prefix without regenerating; only
  deviation/exhaustion triggers a new request.
- Single-flight generation (killed an 831-req → 18-shown stale-discard storm); the
  result is reconciled against typed-since text.
- Token streaming (JSONL `{"p":...}`, deduped, stop at sentence end); UI paints live.
- Speculative prefetch near exhaustion; debounce 80 → 25ms (later 110, see 9c3e0db).
- Huge-`AXValue` guard (terminals expose ~400k chars) → keystroke-buffer fallback.

Context & personalization:
- AX context captures before + after the cursor; per-app sessions keyed by
  `bundleID|appName` (buffer/background/caret/prediction reset on switch).
- Background = window AX scrollback + clipboard; screen-OCR context off by default.
- Local style memory (`style.txt`, deduped sample primed into the prompt); accept/ignore
  stats persisted to `stats.json`.

Typo (off by default): reworked onto `NSSpellChecker` as a strikethrough diff; exact
AX-range replacement with keystroke fallback; the big AX read happens only on accept.

Menu bar: live toggles persisted to `config.toml`; shows model / accept-rate /
learned-style count; Clear Learned Style, Open Config…, Open Log…, Quit.

Packaging: builds against Homebrew llama.cpp (GGUF-only; MLX/Python fallback removed;
model auto-discovered); stable self-signed signing (`make_signing_cert.sh`, designated
requirement anchored to the cert, not the cdhash); repo cleaned for public release, MIT.

## 6ce4e70 / e64a35a / cb7d85b / 34dc5c5 / a536ee9 / b4fc854 — typr.frgmt.xyz site + docs

Marketing site at typr.frgmt.xyz (bun + vite + WebGL shader, Cloudflare-deployed):
instanced cubes that rise and diffuse to "generate" the command block (denoise reveal),
pokeball-style rattle, a typewriter command with a shimmering border, and faded
instanced-cube background streamers. Docs: README refreshed for streaming / text-marker
caret / OCR-off / typo-off; added this CHANGELOG.
