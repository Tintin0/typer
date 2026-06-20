# Typer

**Local, on-device autocomplete for macOS.** Typer shows a faint inline suggestion right
at your cursor in (almost) any text field — keep typing to follow it, press <kbd>Tab</kbd>
to take a word, or <kbd>`</kbd> to take the whole thing. Everything runs on your Mac with
[llama.cpp](https://github.com/ggml-org/llama.cpp) and a small GGUF model — no cloud, no
account, no Apple Developer Program.

🌐 **[typr.frgmt.xyz](https://typr.frgmt.xyz)** · 📓 [Changelog](CHANGELOG.md) · 🛠 [Contributing](CONTRIBUTING.md)

> **Status: alpha.** Feels good in native and Electron/WebKit apps; terminals and
> custom-drawn editors still have approximate caret placement. Feedback and PRs welcome.

## What it does

- **Inline ghost-text completions** at your caret, streaming word-by-word (first word in
  well under ~100ms).
- **Type-into-the-suggestion** — as long as you type what it predicted the ghost just
  shrinks; it only re-thinks when you diverge.
- **Learns your voice** locally — it primes the model with how *you* actually write.
  Nothing leaves your Mac; clear it any time.
- **Per-app context**, plus opt-in window-text, clipboard, and topic memory (all on-device).
- **Typo correction** via the macOS spell checker (off by default).

| Key | Action |
|-----|--------|
| <kbd>Tab</kbd> | Accept the next word |
| <kbd>`</kbd> (backtick) | Accept the whole suggestion |
| <kbd>Esc</kbd> | Dismiss |
| *(keep typing)* | Follow along — matching keystrokes consume the ghost |

## Requirements

- macOS 14 (Sonoma) or later — Apple Silicon recommended
- [Xcode Command Line Tools](https://developer.apple.com/) — `xcode-select --install`
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/frgmt0/typer.git
cd typer
./install.sh
```

`install.sh` installs llama.cpp, downloads a model, writes a default config, and builds
`~/Applications/Typer.app`. Then launch it:

```bash
open ~/Applications/Typer.app
```

On first launch, **onboarding** walks you through permissions and picking a model size.

### Permissions (System Settings → Privacy & Security)

- **Accessibility** — *required.* How Typer reads what you type and inserts suggestions.
- **Screen Recording** — *optional.* Only for caret placement in terminals + on-screen context.

Onboarding links you straight to the right pane. After a rebuild you may need to re-grant
Accessibility — see [stable signing](CONTRIBUTING.md#stable-signing) to make the grant stick.

## Using it

Click the **⌨︎ menu-bar icon** for everything: toggle features live, switch model size, see
accept-rate stats, clear your learned style, open the config/log, or check for updates.

- **Model size** — pick **Small** (fast, runs on any Mac) or **Large** (higher-quality
  suggestions, best on 16 GB+ of RAM). Large downloads once, on demand, and switches live —
  no restart. Change it from the menu dropdown or during onboarding.

## Updating

Typer builds from source, so updating means pulling the latest and rebuilding. Either:

```bash
./update.sh        # fast-forward to the latest, rebuild, relaunch
```

…or click the **↻** button in the menu-bar popover — it fetches, tells you how many commits
behind you are, then rebuilds and restarts in the background (progress in
`~/Library/Logs/Typer-update.log`). It only fast-forwards, so local changes are never
overwritten.

## Privacy

Everything is local — the model runs on your machine and nothing is sent anywhere.

- **Secure input is never captured** — password fields, the login window, `sudo`, password
  managers: no buffering, learning, logging, or generation.
- **The log is not a keylogger** — by default it records no typed text (only counts/events).
- **Your files are yours** — `style.txt` and `stats.json` live under
  `~/Library/Application Support/typer/` (mode `0600`); wipe them any time
  (Menu → *Clear Learned Style* / *Reset All Data*).

## Get your AI coding agent up to speed

Hacking on Typer with Claude Code, Cursor, or similar? Paste this to orient your agent fast:

> You're contributing to **Typer**, a local on-device autocomplete app for macOS (Swift/AppKit +
> SwiftUI front end, a C++ llama.cpp helper, and a Python training pipeline). Get oriented before
> we change anything:
> 1. Read `README.md` and `CONTRIBUTING.md`.
> 2. Map the architecture: the menu-bar app in `scripts/typer/` — start at `TyperApp.swift` (the
>    core `TyperApp` class) and its `extension TyperApp` files split by concern (`+EventTap`,
>    `+Completion`, `+Caret`, `+Context`, `+Menu`, `+Model`); the generation helper
>    `scripts/llama_server.cpp` (llama.cpp over a JSONL stdin/stdout protocol); and the model
>    work in `training/` (read `training/README.md`).
> 3. Note the flow: `scripts/build.sh` compiles the Swift app + C++ server, signs, and installs
>    to `~/Applications/Typer.app`; `./update.sh` pulls + rebuilds.
>
> Then give me a short summary of (a) how a keystroke becomes ghost-text at the caret, (b) how the
> model is selected and loaded (Small vs Large), and (c) where completion quality is tuned. Ask
> before editing anything.

## Contributing

PRs welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)** for the build/run flow, project layout,
architecture, configuration, and the model-training pipeline.

## License

MIT — see [LICENSE](LICENSE). Bring your own model (subject to that model's license).
