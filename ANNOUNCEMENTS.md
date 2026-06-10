# Announcements

<!--
FORMAT STANDARD — read this before adding an entry.

The site (typr.frgmt.xyz/announcements) parses this file at build time.
Anything that doesn't follow the format below won't render.

Structure
  - Entries are newest-first. The topmost entry is featured on the site;
    the rest collapse into dropdowns.
  - Every entry starts:  ## YYYY-MM-DD — title
    (em dash, with spaces). Headers that don't match are ignored.
  - First paragraph is the lede: 1–3 sentences, plain words, the "why you
    care". The site may show it even when the entry is collapsed.
  - Then optional bullets. Each bullet leads with a **bolded phrase.**
  - Optional closing paragraph.
  - Markdown allowed in bodies: **bold**, `code`, [links](url), - bullets.
    Nothing else — no headings, images, tables, or HTML.

Voice
  - Genuinely happy, never hyped. "this one feels great" yes;
    "revolutionary" no. One exclamation point per entry, max.
  - Real numbers only, and only ours: if we measured 60% → 0%, say that.
    Never round a vibe into a statistic.
  - Announcements describe what you FEEL; the CHANGELOG holds the
    engineering. Link it instead of re-explaining.
  - Plain "we" and "you". Admit rough edges — alpha is alpha.
  - lowercase, like the rest of the site. Keep titles under ~60 chars.
-->

## 2026-06-09 — typer got faster in a way you can feel

this one's our favorite kind of update: nothing new to learn, everything just feels quicker. the model used to re-read your whole context on nearly every pause — in an 800-keystroke test it now re-reads 12 times instead of 800, so suggestions spend their time on the new words, not the old ones.

- **rapid Tab is fixed.** hammering `tab` used to occasionally tab you out of the text field mid-sentence. typer now holds the key for a moment while the next chunk arrives, so Tab always means "more words", never "goodbye".
- **the next suggestion comes right away.** after you accept a whole suggestion, the follow-up now starts generating in ~60ms instead of waiting out the typing debounce. you asked for more — no need to make you wait.
- **the ghost stopped drifting.** accepting several words in a row used to nudge the ghost slightly right of your caret. it now snaps back exactly where it belongs, every time.
- **clicking is not typing.** placing your cursor with the mouse no longer summons a suggestion — typer quietly refreshes its context and waits for you to actually type.
- **smarter in chats.** the context window grew, and suggestions adapt better to Discord/iMessage-style phrasing instead of collapsing into generic sentence-finishers.

a stack of smaller caret and prompt wins landed too — the [changelog](https://github.com/frgmt0/typer/blob/main/CHANGELOG.md) has every gory detail.

## 2026-06-02 — one giant file became twenty tidy ones

confession: typer's menu-bar app was a single 2,487-line Swift file. it now lives in [scripts/typer/](https://github.com/frgmt0/typer/tree/main/scripts/typer) as one file per concern — completions, caret, event taps, config, stats, the lot. zero behavior changed; this is purely us making the codebase nicer to read.

if you've been curious about contributing, this is the best time yet to go poke around. PRs welcome — that promise is real.

## 2026-05-30 — spell-fix now works in Discord, Slack, and VS Code

typo correction had an embarrassing habit in Electron apps: accept a fix for `peopel` and you'd get `peoplepeopel`. turns out those editors quietly ignore the accessibility API while claiming they didn't. typer now checks its work and falls back to honest keystrokes when an app lies to it.

- **the fix replaces the word.** backspace the exact length, paste the correction, put your caret back where it was. boring, deterministic, correct.
- **space surfaces the fix.** finishing a misspelled word with `space` now shows the correction even while a suggestion is on screen.

typo correction is still off by default while we polish it — flip it on in the menu if you want to live a little.

## 2026-05-30 — typer can remind you of what you just read

new opt-in feature we're quite fond of: topic memory. every few minutes typer OCRs your focused window (Apple Vision, on-device), distills just the topics — names, products, a one-line note — and stores them locally. later, when you type "those Sony headphones I saw…", the details resurface in your suggestion.

- **distilled, not hoarded.** it keeps entities and a 1–2 sentence note, never raw screen text, and only chimes in when a distinctive word you read shows up in what you're typing.
- **respectfully cheap.** it skips terminals, secure input, and battery-saver, and Reset All Data wipes it like everything else.

off by default (it needs Screen Recording permission). menu → context sources → "remember what I read".

## 2026-05-30 — a day spent shaving milliseconds

no headline feature today, just a pile of small efficiencies that add up: the helper stopped replaying ~1024 tokens of prompt through the sampler on every request, hot-path disk reads and per-keystroke log writes are gone, speculative prefetch now politely yields to your actual typing, and ~120 lines of dead code left the building.

oh — and the menu-bar icon could previously render at zero width, i.e. be invisible. it's a keyboard symbol with your accepted-words count now. you'd be surprised how long you can ship an invisible icon without noticing.

## 2026-05-30 — we found the battery drain. it was us. sorry

profiling showed idle typer at ~60% CPU — not the model, but our own event tap stuck in a re-enable loop, having a very fast argument with macOS about whether it should be awake. fixed: **idle CPU went from 60% to 0%.**

- **one generation per pause.** the debounce was shorter than the gap between keystrokes, so typer ran inference on nearly every character. it now coalesces a burst of typing into a single generation.
- **battery-saver mode.** on battery or Low Power Mode, typer automatically debounces harder and skips speculative prefetch. it's on by default; the menu shows when it's throttling.

your fans should now stay quiet until you've actually earned the noise.

## 2026-05-29 — the ghost grew up

a big pass on the thing you look at all day. the ghost text is now drawn with Core Animation — matched to your caret line, a soft taper at the edge, a one-shot shimmer when a fresh suggestion lands — and it no longer lags or overlaps what you're typing.

- **it stays out of your keyboard.** event taps were rearchitected so typer only ever consumes a key while a suggestion is actually showing. no suggestion, no interference — your input never waits on us.
- **accepting text skips the clipboard.** accepted words are typed as a synthesized keystroke, so your pasteboard stays yours.
- **per-app off switch.** disable typer in specific apps, skip terminals entirely, and Reset All Data from the menu when you want a clean slate.

## 2026-05-29 — we asked a reviewer to attack typer. it found things

we ran an adversarial security review on the whole pipeline and fixed everything it flagged. the highlights: typer now goes completely inert during macOS secure input (password fields, `sudo`, password managers) — no buffer, no learning, no logging, nothing. logs are off by default and file permissions got strict (`0600`). the clipboard reader skips concealed items like password-manager copies.

none of this changed how typer feels — that's the point. local-and-private is a promise, and promises get audited.

## 2026-05-29 — fewer random words, and your stats got fun

two unrelated things that both made us smile. first, a sampling overhaul: a min-p sampler and tighter settings mean suggestions drift into random-word territory far less, and the overlay stopped flickering while you type through it.

second: the menu now tracks words completed, daily streak, and translates your total into books — accept enough suggestions and you'll learn you've typed 0.3 Hobbits. is this necessary? no. do we love it? yes.

## 2026-05-29 — hello! typer is public

first public release, and the foundation everything above is built on: inline ghost-text suggestions at your caret in almost any app, streaming in word-by-word with the first word in ~80ms. `tab` takes a word, `` ` `` takes everything, `esc` says no thanks — or just keep typing and the ghost follows along without regenerating.

- **it learns your voice, locally.** a small on-device record of what you actually write primes the model toward how you sound. clearable any time.
- **per-app sessions.** your group chat and your code don't share a brain.
- **MIT, free, no account.** one `./install.sh`, a small GGUF model, and llama.cpp. that's the whole stack, and it all runs on your Mac.

alpha, honestly: caret placement in terminals and custom editors is approximate, and quality depends on your model. we're just getting started — [come watch](https://github.com/frgmt0/typer), or better, come help.
