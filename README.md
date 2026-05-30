# Typer

**Local, on-device autocomplete for macOS.** Typer watches what you type in any
text field and shows a faint inline suggestion right at your cursor. Keep typing
to follow it, press <kbd>Tab</kbd> to take a word, or <kbd>`</kbd> to take the
whole thing. Everything runs locally with [llama.cpp](https://github.com/ggml-org/llama.cpp)
and a small GGUF model — no cloud, no account, no Apple Developer Program.

🌐 **[typr.frgmt.xyz](https://typr.frgmt.xyz)** · 📓 [Changelog](CHANGELOG.md)

> **Status: alpha.** It feels good in native and Electron/WebKit apps now;
> terminals and custom-drawn editors still have approximate caret placement, and
> quality depends on your model. Feedback and PRs welcome.

---

## What it does

- **Inline ghost-text completions** (5–7 words) at your caret, in (almost) any app.
- **Type-into-the-suggestion**: as long as you type what it predicted, the ghost
  just shrinks — it doesn't regenerate. It only re-thinks when you diverge.
- **Streaming**: the ghost appears word-by-word as the model generates, so the
  first word shows in well under ~100ms instead of waiting for the whole phrase.
- **Typo correction** via the macOS spell checker, shown as a strikethrough diff
  (<kbd>Tab</kbd> to accept). *Off by default in this build* — enable it in the
  menu or config.
- **Per-app sessions**: each app keeps its own typing context, so switching apps
  starts fresh instead of bleeding context between a chat and your code.
- **Learns your voice**: keeps a small local record of what you actually write
  (sent messages, text you type, completions you keep) and primes the model with it
  so suggestions drift toward how *you* write. It also tracks how often you accept
  vs. type past suggestions (shown in the menu). All on-device; clearable any time.
- **Context-aware**: pulls in the surrounding text of the focused window and your
  recently copied text. (An optional screenshot-OCR context source exists but is
  **off by default** — it tended to be noisy.)
- **Topic memory** (opt-in): every few minutes Typer can OCR the focused window (Apple
  Vision, on-device), distill the **salient topics** — named entities + key nouns +
  a short snippet — and store them locally. Later, when you type about one of those
  things, the snippet is folded in so it can help you recall it (read a product page,
  then mention it to a friend and the details resurface). It only injects when a
  distinctive keyword you read appears in what you're typing — never raw screen text.
  Off by default; needs Screen Recording; clearable; skips terminals/secure input.

### Keys

| Key | Action |
|-----|--------|
| <kbd>Tab</kbd> | Accept the next word (the rest stays) |
| <kbd>`</kbd> (backtick) | Accept the entire suggestion |
| <kbd>Esc</kbd> | Dismiss the suggestion |
| *(just keep typing)* | Follow along — matching keystrokes consume the ghost |

---

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon recommended.
- [Xcode Command Line Tools](https://developer.apple.com/) — `xcode-select --install`
- [Homebrew](https://brew.sh) (used to install llama.cpp)

## Install

```bash
git clone https://github.com/frgmt0/typer.git
cd typer
./install.sh
```

`install.sh` will:
1. `brew install llama.cpp`
2. download a GGUF model into `~/Library/Application Support/typer/Models/`
3. write a default config to `~/Library/Application Support/typer/config.toml`
4. build and install `~/Applications/Typer.app`

Then grant permissions and launch (see below).

### Permissions (System Settings → Privacy & Security)

- **Accessibility → enable Typer** — *required.* This is how Typer reads your
  keystrokes and text context and inserts accepted suggestions.
- **Screen Recording → enable Typer** — *optional.* Only needed for caret placement
  in apps that expose no cursor at all (terminals, custom editors) and for the
  off-by-default screen-OCR context. Native and Electron/WebKit apps don't need it.

```bash
open ~/Applications/Typer.app
tail -f ~/Library/Logs/Typer.log   # watch what it's doing
```

A ⌨︎ icon appears in your menu bar. Click it to toggle features live (Enabled,
Completions, Typo, context sources), see the model, accept-rate stats, and learned
style count, clear learned style, or open the config/log — no file editing needed.

### Stable signing (recommended)

By default the app is ad-hoc signed, so macOS resets its Accessibility grant on
every rebuild. To keep the grant across rebuilds, create a one-time self-signed
certificate (no Apple Developer Program needed):

```bash
./scripts/make_signing_cert.sh   # approve the macOS dialog + enter your login password
./scripts/build.sh
```

After this, `./scripts/build.sh` re-signs with the same identity and the grant sticks.

---

## Model

Typer uses any GGUF the runtime can load; it auto-picks the first `.gguf` in the
Models directory. The default download is set in `install.sh`:

```bash
TYPER_MODEL_REPO="unsloth/gemma-4-E2B-it-GGUF"
TYPER_MODEL_FILE="gemma-4-E2B-it-Q4_K_M.gguf"
```

To use a different model, either drop a `.gguf` into
`~/Library/Application Support/typer/Models/` (and set `model_path` in the config),
or re-run the installer with an override:

```bash
TYPER_MODEL_URL='https://huggingface.co/<repo>/resolve/main/<file>.gguf' ./install.sh
```

**Tip:** completion is raw text *continuation*, so a **base / pretrained**
(`-pt`/`-base`) model often feels more natural for autocomplete than an
instruction-tuned (`-it`) one. Smaller models (0.5–2B) are faster; larger ones are
more coherent. Experiment.

---

## Configuration & tinkering

Edit `~/Library/Application Support/typer/config.toml` and restart Typer
(`pkill -f Typer.app/Contents/MacOS/Typer; open ~/Applications/Typer.app`).
See [`config.example.toml`](config.example.toml) for all options, including:

- `completion_enabled`, `typo_correction_enabled`
- `max_completion_words`, `debounce_ms`, `min_context_chars`
- the context toggles: `window_context_enabled`, `style_memory_enabled`,
  `clipboard_context_enabled`, `screen_context_enabled`, `topic_memory_enabled`
  (+ `topic_capture_seconds`)

### Sampling / prompt

Generation lives in [`scripts/llama_server.cpp`](scripts/llama_server.cpp) — a tiny
JSONL stdin/stdout helper around llama.cpp. Temperature, top-k/p, repetition
penalty, the `<bos>` handling, mid-word suppression, and spacing rules are all
there. After editing, rebuild with `./scripts/build.sh`.

### Frontend

The menu-bar app, event tap, overlay, follow-along logic, AX/screenshot caret
placement, and context gathering are in
[`scripts/typer_native.swift`](scripts/typer_native.swift).

---

## How it works

```
  keystrokes ─▶ Swift app (CGEvent tap, Accessibility)
                  │  builds context: text before cursor + window text +
                  │  clipboard + your style sample
                  ▼
            typer-llama-server  (C++ / llama.cpp, persistent JSONL process)
                  │  <bos> + context  ──▶  streams next-word continuation
                  ▼
            ghost overlay at the caret;  Tab / ` / type-through to accept
```

- **Why `<bos>`:** Gemma is trained with a leading begin-of-sequence token; without
  it the model produces repetitive garbage. The helper always prepends it.
- **Speed feel:** completions **stream** in word-by-word, and the model runs ~once
  per 5–7-word chunk (not per keystroke) — while you type *along* a suggestion
  nothing is regenerated, and the next chunk is prefetched in the background.
- **Caret placement:** Accessibility `AXBoundsForRange` in native AppKit apps; the
  `AXTextMarker` API in Chromium/WebKit apps (Discord, Slack, VS Code, Chrome,
  Safari); and a screenshot + OCR locator as a last resort for apps that expose no
  cursor at all (terminals, custom editors).

---

## Personalization

Typer learns your writing **locally** and uses it to prime the model:

- It records substantive things you write — sent messages, text you type, and
  completions you keep — to `~/Library/Application Support/typer/style.txt`, and
  feeds a recent sample into each prompt so suggestions sound more like you.
- It tracks **shown / accepted / ignored** suggestion stats (menu bar → the ⌨︎
  icon). "Ignored" means a suggestion was shown but you typed something else.
- **Menu → Clear Learned Style** wipes the corpus. Disable entirely with
  `style_memory_enabled = false`.

It never fine-tunes or uploads anything — personalization is purely the local
style sample plus your per-app session text.

## Privacy

Everything is local. The model runs on your machine; nothing is sent anywhere.

- **Secure input is never captured.** While macOS secure input is active — password
  fields, the login window, `sudo` prompts, password managers — Typer captures
  nothing: no buffering, no learning, no logging, no AX reads, no generation.
- **The log is not a keylogger.** By default the log records no typed text or
  text snippets (only counts/events), and is created `0600`. Set
  `debug_logging = true` to include snippets for troubleshooting.
- **Local files are private.** `style.txt` (learned writing) and `stats.json` live
  under `~/Library/Application Support/typer/` (mode `0600`) — delete them any time
  (Menu → Clear Learned Style wipes the style corpus).
- **Clipboard context skips secrets.** Content password managers mark concealed /
  transient is never read into the prompt.
- Window-text reads and the (off-by-default) screen OCR stay on-device and are only
  used to build the local prompt.

---

## Limitations (alpha)

- Caret placement in terminals / custom-drawn editors is approximate and needs
  Screen Recording (native + Electron/WebKit apps are exact).
- The model streams, but full warm generation is still ~0.4s; very fast typists may
  see brief flicker as suggestions update.
- Mid-word completions are suppressed (the small base model isn't reliable at them).
- Quality depends heavily on the model you choose.

## Battery

The model runs on the GPU, so battery use scales with how often it generates. Typer
keeps this in check:

- It generates on a **pause**, not on every keystroke (`debounce_ms`, default 110).
- **Battery saver** (on by default) stretches the debounce and disables speculative
  prefetch while on battery or in Low Power Mode — toggle in the menu (it shows
  "throttling now" when active), or tune `battery_saver` / `battery_debounce_ms` /
  `prefetch_enabled` in the config.
- For maximum battery life, use a **smaller model** (the single biggest lever) and/or
  raise `debounce_ms`.

## Troubleshooting

- **No suggestions / `AX trusted=false` in the log** → grant Accessibility to
  Typer, then relaunch. After a rebuild, re-grant unless you set up stable signing.
- **Battery draining fast** → it's the model's GPU use. Make sure Battery saver is on
  (menu), raise `debounce_ms`, or switch to a smaller GGUF. See **Battery** above.
- **Suggestions appear at the bottom of the screen** → that app exposes no caret to
  Accessibility (often a terminal); enable Screen Recording for the OCR-based locator.
- **Garbage completions** → try a different / base model; the sampling temperature
  is already conservative in the helper.
- **Watch the log:** `tail -f ~/Library/Logs/Typer.log`

## License

MIT — see [LICENSE](LICENSE). Bring your own model (subject to that model's license).
