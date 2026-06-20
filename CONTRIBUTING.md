# Contributing to Typer

Thanks for hacking on Typer. This covers how to build it, how it's laid out, and how to
change the parts you'll most likely want to touch. (User-facing setup is in the
[README](README.md).)

## Contributing flow

- Open a PR against `main`. Keep it focused; describe larger changes in [`CHANGELOG.md`](CHANGELOG.md).
- Commit messages are short and concise — one line on *what* changed. Detail goes in the
  changelog, not the commit.
- The Swift app compiles as a single module (`scripts/typer/*.swift`), so a new file is picked
  up automatically by `build.sh`. Type-check fast with `swiftc -typecheck scripts/typer/*.swift`.

## Build & run

```bash
./scripts/build.sh
```

`build.sh` compiles the C++ llama.cpp helper (`scripts/llama_server.cpp`) and the Swift
menu-bar app (`scripts/typer/*.swift`), assembles `~/Applications/Typer.app`, signs it, and
restarts. llama.cpp is resolved from Homebrew (`brew install llama.cpp`), `$TYPER_LLAMA_PREFIX`,
or a local `vendor/llama.cpp`.

`./update.sh` is the same build wrapped in a `git` fast-forward (pull → rebuild → relaunch); it
backs the menu-bar **Check for updates** button and stamps the source path + commit into the app
bundle so the app can find its own checkout.

### Stable signing

By default the app is ad-hoc signed, so macOS resets the Accessibility grant on every rebuild.
Create a one-time self-signed certificate (no Apple Developer Program) so the grant sticks:

```bash
./scripts/make_signing_cert.sh   # approve the dialog + enter your login password
./scripts/build.sh
```

After this, every `build.sh` re-signs with the same identity.

## Project layout

```
scripts/llama_server.cpp   C++ helper around llama.cpp: a persistent JSONL stdin/stdout process
scripts/build.sh           build + sign + install; update.sh wraps it with a git pull
scripts/typer/             the Swift menu-bar app (one module)
training/                  Python pipeline to train Typer's own small model (see training/README.md)
docs/                      design docs (autocomplete-model.md is the model plan)
web/                       the marketing site (Cloudflare Worker; auto-deploys via GitHub Actions)
```

The Swift app is split by concern. The core `TyperApp` class and its stored state live in
`TyperApp.swift`; everything else is an `extension TyperApp` per topic:

- `TyperApp+EventTap.swift` — CGEvent taps and the type-along loop
- `TyperApp+Completion.swift` — generation, prefetch, ghost placement
- `TyperApp+Caret.swift` — Accessibility / screenshot caret placement
- `TyperApp+Context.swift` — window text, OCR, clipboard, topic memory
- `TyperApp+Menu.swift` — the menu-bar popover + actions
- `TyperApp+Model.swift` — Small/Large model switching + on-demand download
- `TyperApp+Typo.swift`, `+Input.swift`, `+Stats.swift`

Supporting types each get a file: `ModelRouter.swift`, `LlamaClient.swift`, `ModelDownloader.swift`,
`MenuPopover.swift`, `OnboardingWindow.swift`, `SuggestionOverlay.swift`, `GhostView.swift`,
`StyleMemory.swift`, `TopicMemory.swift`, `TyperConfig.swift`, … `main.swift` is the entry point.

## How it works

```
  keystrokes ─▶ Swift app (CGEvent tap, Accessibility)
                  │  builds context: text before cursor + window text +
                  │  clipboard + your local style sample
                  ▼
            typer-llama-server  (C++ / llama.cpp, persistent JSONL process)
                  │  context  ──▶  streams the next-word continuation
                  ▼
            ghost overlay at the caret;  Tab / ` / type-through to accept
```

- **Streaming + chunking** — completions stream word-by-word; the model runs ~once per 5–7-word
  chunk (not per keystroke), nothing regenerates while you type *along*, and the next chunk is
  prefetched.
- **Caret placement** — `AXBoundsForRange` in native AppKit apps; the `AXTextMarker` API in
  Chromium/WebKit apps (Discord, Slack, VS Code, Chrome, Safari); and a screenshot + OCR locator
  as a last resort for apps that expose no cursor (terminals, custom editors).
- **BOS** — the helper prepends the model's begin-of-sequence token only when its tokenizer
  declares one (Gemma yes; Qwen3 / SmolLM2 base no), via `llama_vocab_get_add_bos`.

## Configuration & tinkering

Edit `~/Library/Application Support/typer/config.toml` and restart Typer
(`pkill -f Typer.app/Contents/MacOS/Typer; open ~/Applications/Typer.app`). See
[`config.example.toml`](config.example.toml) for everything, including completion/typo toggles,
`max_completion_words`, `debounce_ms`, the context sources, and `model_variant` (`small`/`large`).

**Generation** lives in [`scripts/llama_server.cpp`](scripts/llama_server.cpp): the sampler
(greedy by default — `TYPER_SAMPLER=nucleus` restores the tuned nucleus sampler), repetition
penalty, mid-word suppression, echo removal, spacing, and a `mode:"raw"` path used by the eval.
Rebuild after editing with `./scripts/build.sh`.

## Models

Typer loads any GGUF llama.cpp can read, from `~/Library/Application Support/typer/Models/`:

- **Small** races the on-device `typer-1-*.gguf` models (a graded-reward A/B between two arms,
  locking the winner) — see `ModelRouter.swift`. With fewer than two it just serves the single
  model present.
- **Large** (`typer-1l.gguf`) is served on its own (no race), downloaded on demand when selected.

Completion is raw text *continuation*, so a **base / pretrained** model usually feels more natural
than an instruction-tuned one. Smaller is faster; larger is more coherent.

## Training Typer's own model

`training/` is a full pipeline to train a sub-1B autocomplete model on Apple Silicon (SFT →
distillation → quantize → GGUF), plus the diagnostic eval that compares the harness vs the raw
model and ranks candidate teachers. Highlights:

- `eval_compare.py` — the typed-content eval (harness-vs-raw + teacher ranking)
- `distill_teacher_batch.py` — distill from a Claude teacher via the Batch API
- `collect_human_data.py` / `expand_human_data.py` / `mine_capture.py` — the human-grounded data
  pipeline (collect real writing, expand it, mine local capture)
- `mem_guard.sh` — hard RAM cap for the (resumable) training run

Start with [`training/README.md`](training/README.md) and the design doc
[`docs/autocomplete-model.md`](docs/autocomplete-model.md). Opt-in capture for training data is
enabled from the menu (*Record my typing*) and is screened + `0600` + clearable.

## Privacy architecture

The invariant: nothing user-derived leaves the device.

- **Secure input** (passwords, login window, `sudo`, password managers) is never captured — no
  buffering, learning, logging, AX reads, or generation while it's active.
- **The log** records no typed text by default (`debug_logging = true` adds snippets for
  troubleshooting) and is created `0600`.
- **Local stores** (`style.txt`, `stats.json`, `training.jsonl`, lexicon) are `0600`, clearable
  from the menu, and never uploaded.
- **Clipboard context** skips content marked concealed/transient by password managers.
- The training pipeline uses public corpora + your own (cleaned, screened) capture; the
  `/data/` dir is gitignored so collected writing is never committed.
