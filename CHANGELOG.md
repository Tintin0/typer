# Changelog

Typer is in **alpha** and not yet versioned — entries are grouped by date. Website:
[typr.frgmt.xyz](https://typr.frgmt.xyz).

## Alpha — 2026-05-30 (battery — the real fix)

The big one: **the app was burning a full CPU core continuously, even when idle and
not generating anything.** This — not the model — was the battery drain (one user got
~3h of runtime). Found by sampling the process: ~60% CPU was being spent in
`accept() → SLEventTapEnable → mach_msg`.

- **Fixed an event-tap enable/disable spin.** The consuming "accept" tap (which grabs
  Tab/backtick) is toggled on only while a suggestion shows. Each toggle is a
  *blocking* round-trip to the WindowServer, and on every `tapDisabled` notification we
  re-issued it — including when nothing was showing, where our own disable echoed back
  and we re-enabled in a tight loop. The tap state is now mirrored locally (no
  redundant round-trips) and we never re-arm while idle. **Idle CPU went from ~60% to
  0%.**
- **Screenshot-OCR caret locator is now off by default.** For apps with no
  Accessibility caret (terminals like Ghostty, custom editors) Typer used to take a
  full ScreenCaptureKit screenshot and run Vision OCR — on the Neural Engine — roughly
  every second while typing. That's far too heavy to run continuously. It's now opt-in
  (menu → Context sources → "Screenshot caret", or `screenshot_caret_enabled`), and
  when on it recomputes far less often. Native and Electron/WebKit apps are unaffected
  (they use the cheap AX/text-marker caret).

## Alpha — 2026-05-30 (battery)

Typer was *also* firing a full model inference far more often than it needed to. The
model runs on the GPU; these reduce how often it runs:

- **Generate on a pause, not on every key.** The debounce was 25ms — *shorter* than
  the gap between keystrokes (~80–200ms), so the "wait" expired between nearly every
  character and we ran a full model inference each time. Default debounce is now
  **110ms**, so generation fires once you actually pause. (Imperceptible to typing
  feel; the suggestion still streams in.)
- **Battery saver (on by default).** On battery or in Low Power Mode, Typer stretches
  the debounce to 300ms and turns off speculative prefetch (which otherwise runs a
  *second* inference as you type along a suggestion — ~2× the GPU work). Desktops and
  plugged-in laptops are unaffected. Toggle in the menu; the item shows
  "(throttling now)" while it's active. New config: `battery_saver`,
  `battery_debounce_ms`, `prefetch_enabled`.
- **Fewer CPU wakeups reading the model's output.** The helper's streamed response was
  read one byte at a time (a `poll`+`read` syscall per character); it now reads in 4KB
  chunks. macOS energy impact is dominated by wakeups, so this matters.
- Background context (window text / clipboard) also refreshes less often while saving
  power.

## Alpha — 2026-05-30 (overlay polish)

- **Ghost no longer overlaps the text you're typing.** Our keyboard tap fires before
  the host app applies the keystroke, so reading the caret right after typing was
  stale (one step behind). The overlay now moves immediately by the measured width of
  what was typed, then re-anchors precisely a beat later — so it tracks your cursor as
  you type through a suggestion and after Tab, instead of lagging ~0.5s.
- **Nicer-looking ghost text** (Core Animation renderer): SF system font sized to your
  line, a **soft taper** that fades the trailing edge, and a one-shot **shimmer sweep +
  fade-in** when a fresh suggestion appears (calm while you type through it).

## Alpha — 2026-05-30 (stability + control)

- **Fixed words being skipped on fast Tab.** Injected insertion events are now
  tagged and ignored by exact marker, so a quick second Tab is never mistaken for
  our own event (the old count/timing guard raced it).
- **Reworked the event taps** (idea from cotabby): a **listen-only observer** that
  can never stall global keystrokes in other apps, plus a **consuming accept tap
  that's only active while a suggestion is on screen** — the rest of the time Typer
  consumes no keys at all. This is the main stability fix.
- **Per-app disable + terminal skip.** Menu → "Disable in <app>" and "Skip terminal
  apps". Typer stays silent there.
- **Clipboard is only used when relevant** — a long copied blob is ignored unless it
  shares a word with what you're writing.
- **Menu → Reset All Data…** wipes learned style + stats (with a confirmation),
  keeping your settings.

## Alpha — 2026-05-30 (insertion + drift)

- **Accepting no longer touches your clipboard.** Inserted text is now typed via a
  synthesized Unicode keystroke (idea from [cotabby](https://github.com/FuJacob/cotabby))
  instead of a copy/paste, with a self-suppression guard so it isn't re-processed as
  typing. The pasteboard path remains only for the (off-by-default) typo fallback.
- **Less ghost drift while typing through a suggestion** — the overlay re-anchors to
  the real caret at each word boundary (handles line-wrap), and shifts by measured
  width within a word.
- Completions keep settling in long fields / after a pause (staleness check is now
  robust to buffer truncation and idle-reset).
- Mid-line completions are suppressed whenever any text remains on the line after the
  caret. Helper clears its KV cache on context front-truncation. Removed dead config
  knobs. Fixed a screenshot-capture result race.

## Alpha — 2026-05-30 (hardening pass)

Adversarial review of the whole codebase (concurrency, the C++ helper, pipeline
logic, security). Fixes:

### Security & privacy
- **Never capture secure input.** While macOS secure input is active (password
  fields, login window, `sudo`, password managers) Typer now captures nothing —
  no buffer, no learning, no logging, no AX reads, no generation.
- **Log is no longer a keystroke transcript.** Typed text and snippets are gated
  behind `debug_logging` (default off); the log and `style.txt` are now `0600`.
- **Clipboard context skips concealed/transient items** (password-manager copies).
- **install.sh**: optional `TYPER_MODEL_SHA256` verification; reject path
  separators in the model filename. **build.sh**: safe array globbing for dylibs.

### Robustness / concurrency
- **Event tap self-heals**: handles `tapDisabledByTimeout`/`ByUserInput` and
  re-enables instead of silently dying.
- **Fixed an off-main data race** on the keystroke buffer (the screenshot-caret and
  background-context closures now snapshot buffer/config on the main thread).
- **Helper can't wedge the app**: model reads now time out (8s) and tear down a
  hung helper so the next request respawns it; warm-up is lock-safe (no
  double-spawn); in-flight flags reset on all paths.
- **Pasteboard is safe**: serialized, restores all clipboard item types (not just
  text), and won't clobber something you copied during the paste window.

### Helper (C++)
- UTF-8-safe streaming partials (no broken multibyte in `{"p":...}`); RAII sampler
  (no leak on a mid-generation error); `max_words` clamped.

### Stats
- Accept-rate is now honest: promoted prefetches count as shown; removed the noisy
  per-keystroke "ignored" counter.

## Alpha — 2026-05-30 (later)

Stability/quality pass informed by studying the open-source
[cotabby](https://github.com/FuJacob/cotabby):

- **Steadier suggestions.** Added a `min-p` sampler (drop tokens below ~6% of the
  top token's probability) and lowered temperature/top-p — far less "random word"
  drift. Sampling is now temp 0.12, top-k 20, top-p 0.80, min-p 0.06, penalty 1.05.
- **Less flicker while typing.** As you type *through* a suggestion the overlay now
  advances by the measured character width instead of re-reading the (jittery) caret
  from Accessibility on every keystroke; the panel also stops re-ordering itself on
  each update.
- **No more giant ghost text.** The ghost font is floored to the smallest caret
  height seen per field, so an occasional bad Accessibility reading can't blow it up.
- **Drop repeated text.** Completions that just repeat what's already after your
  cursor are discarded instead of shown as a confusing partial.
- **No more stray HTML tags.** Markup like `<em>` or `</strong>` that the model
  occasionally emits is now stripped from suggestions (a `<` in `a < b` is kept).
- **New menu-bar badge.** The icon is now `t|N`, where N is your running count of
  accepted completions (updates live; shows `⏸` when paused).
- **Fun stats in the menu.** Opening the menu now shows how much you've
  tab-completed — words, a scaling comparison ("≈ 0.3 Hobbits' worth of words",
  "≈ 12% of a Harry Potter book", etc.), estimated typing time saved, and your
  daily streak / active days. Tracked locally; builds up as you use it.

## Alpha — 2026-05-30

### What you'll notice (plain language)

- **Suggestions are actually good now.** Earlier they were often repetitive or
  nonsense; that's fixed, and they read like natural continuations of your sentence.
- **They show up right where you're typing.** The ghost text sits inline on your
  cursor's line, sized to match the app's font — not floating above or stuck in a
  corner.
- **It feels faster.** Suggestions stream in word-by-word, so the first word appears
  almost instantly instead of waiting for the whole phrase.
- **Type *into* a suggestion.** As long as you keep typing what it predicted, the
  ghost just shrinks — no flicker, no regenerating. <kbd>Tab</kbd> takes one word,
  <kbd>`</kbd> takes the rest.
- **Works in more apps.** Discord, Slack, VS Code, Chrome, and Safari now place the
  suggestion exactly at your cursor (previously only native apps did).
- **It learns how you write.** Typer keeps a private, on-device record of your own
  writing and uses it to make suggestions sound more like you. You can clear it any
  time from the menu.
- **Real menu bar.** Click the ⌨︎ icon to turn features on/off, see your accept rate
  and model, clear learned style, or open the config/log — no file editing.
- **Each app is its own session.** Switching apps starts fresh instead of mixing a
  chat's context into your code.
- **Typo correction is off for now**, so we can focus on perfecting autocomplete
  (re-enable it in the menu).
- **Screenshot/OCR context is off by default** — it was noisy and occasionally
  produced garbage suggestions.

### Technical detail

#### Suggestion quality
- **Root cause fixed:** the helper never prepended Gemma's `<bos>` token (it
  tokenized with `add_special=false`), so the base model produced degenerate,
  repetitive output (`"the the The"`, `"your help with your help with your"`).
  `prompt_complete` now prepends `<bos>`.
- Sampling tuned for predictable inline completions: temperature 0.65 → 0.20,
  top-k 40 → 20, top-p 0.92 → 0.90, repetition penalty 1.12 → 1.08.
- **Preserve the model's spacing intent** instead of force-adding a leading space —
  fixes `"autocompl ition"` and `"cool !"`. A leading-space token means "new word";
  none means "continue this word / punctuation".
- **Suppress mid-word completions:** when the context ends inside a word and the
  model continues it without a leading space (`"autocompl"`→`"ition"`), the small
  base model is unreliable, so we show nothing rather than a wrong guess.
- Confirmed the shipped GGUF reports `chat_template=(null)` (a base model), so raw
  continuation is the correct prompting strategy.

#### Caret & overlay placement
- Fixed the AX→AppKit coordinate flip to use the **primary (zero-origin) screen**
  height, not the local screen (was wrong on multi-monitor).
- Validate AX caret rects (`isPlausibleCaretRect`) and fall through strategies:
  selection → zero-length caret → previous glyph → next glyph → paragraph scan.
- **`AXTextMarker` caret** (`AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`)
  for Chromium/WebKit apps that don't implement `AXBoundsForRange` — exact caret in
  Electron/Safari with no screenshot.
- **Screenshot + OCR caret locator** (ScreenCaptureKit + Vision) as a last resort
  for apps with no caret geometry; cached and extrapolated horizontally during
  typing. (`CGWindowListCreateImage` is unavailable in the macOS 26 SDK.)
- Overlay renders **inline**: font sized to the caret line height and vertically
  centered on the caret line; applies to completions, typo, and grammar.

#### Speed & ergonomics
- **Type-into-suggestion follow-along:** matching keystrokes consume the ghost
  prefix without regenerating; only deviation or exhaustion triggers a new request.
- **Single-flight generation** fixed a stale-discard storm (one run logged 831
  requests → 980 responses → only 18 shown). At most one request is in flight; the
  result is reconciled against typed-since text so it still appears when you've typed
  ahead.
- **Token streaming:** the helper emits partial completions per token (JSONL
  `{"p":...}` lines, deduped, stopping at sentence end); the UI paints them live.
- Speculative **prefetch** of the next chunk near exhaustion; debounce 80 → 25 ms.
- Guard the hot path against huge `AXValue`s (terminals expose ~400k chars) by
  falling back to the keystroke buffer.

#### Context & personalization
- AX context captures text **before and after** the cursor; mid-line edits are
  suppressed.
- **Per-app sessions:** independent buffers keyed by `bundleID|appName`; background
  context, caret cache, and prediction reset on app switch.
- Background context = window AX scrollback + clipboard. **Screen-OCR context is off
  by default** (noisy); when on, OCR is accurate-mode with confidence/garbage
  filtering and only used when AX text is sparse.
- **Local style memory** (`style.txt`): records your committed writing (sent
  messages, app-switch flush, kept completions), deduped, and primes the prompt with
  a recent sample. **Accept/ignore stats** persisted to `stats.json`.

#### Typo correction (off by default)
- Reworked onto **`NSSpellChecker`** (the OS engine) shown as a strikethrough diff;
  exact AX-range replacement with a keystroke fallback. Detection is buffer-cheap;
  the big AX read happens only on accept.

#### Menu bar
- Live toggles for Enabled / Completions / Typo and context sources, persisted to
  `config.toml` immediately. Shows model, accept rate, learned-style count; actions
  for Clear Learned Style, Open Config…, Open Log…, Quit.

#### Packaging & build
- Builds against **Homebrew llama.cpp** (`brew install llama.cpp`) — no third-party
  binaries bundled. GGUF-only; the legacy Python/MLX fallback was removed and the
  model is auto-discovered from the Models directory.
- **Stable self-signed code signing** (`make_signing_cert.sh`) so macOS keeps the
  Accessibility grant across rebuilds; designated requirement is anchored to the
  certificate, not the cdhash.
- Repo cleaned for public release (removed build artifacts and dead code); MIT
  licensed. Bring your own model.
