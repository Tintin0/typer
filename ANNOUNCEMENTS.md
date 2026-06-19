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
  - First paragraph is the lede: 1–3 sentences, the "why you care".
    The site may show it even when the entry is collapsed.
  - Write each paragraph as ONE line (no hard wraps) — the parser turns
    every line break into a new paragraph.
  - Bullets are optional and for actual lists only. Don't reach for them
    by default, and don't open every bullet with a **bolded label:** —
    that's the fastest way to make a real update read like a changelog
    robot wrote it. Prose first. Lists when you genuinely have a list.
  - Markdown allowed in bodies: **bold**, `code`, [links](url), - bullets.
    Nothing else — no headings, images, tables, or HTML.

Voice
  - Write like the person who built the thing and actually cares about it.
    One voice, talking to a real user — not a press release, not a robot
    being cheerful on command.
  - Vary your rhythm. Short sentences. Then a longer one when the thought
    needs the room. If every sentence is the same shape, start over.
  - Genuinely happy, never hyped. "this one feels great" yes;
    "revolutionary" no. One exclamation point per entry, max.
  - Real numbers only, and only ours: if we measured 60% → 0%, say that.
    Never round a vibe into a statistic. No fake superlatives.
  - Admit the rough edges. alpha is alpha, and pretending otherwise is
    the most robotic thing you can do.
  - Announcements are what you FEEL; the CHANGELOG holds the engineering.
    Point at it when you've got nothing left to say — not in every entry.
  - lowercase, like the rest of the site. titles under ~60 chars.
-->

## 2026-06-18: typer-1 grew up, and now two of them fight over your suggestions

we shipped typer-1 and told you it kept pace with gemma. then we built a meaner test set out of the stuff you actually type, half-finished slack messages, code, commit lines, the start of an email, and watched our 360M model come dead last on it. the "matches gemma" number was real; we'd just measured it on wikipedia prose, which is nothing like a person at a keyboard. so we went back and did it properly.

typer-1 has a bigger brain now. still tiny, about a fifth of gemma's size, but with enough room to hold its own on real typing: it lands right next to gemma on the words that matter and puts the first one on your screen in about 23 milliseconds instead of 160. that's the entire point of a small model: you stop noticing it's there.

we don't know which typer-1 is best for *you*, so we stopped guessing and let them fight. two models ship now, a plain one and one we taught by having gemma write thousands of completions for it to imitate. they split your suggestions down the middle, and every time you take one with tab, or just type along with what it guessed, the model that wrote it earns a point, a small one for following loosely, a full one for taking it outright. the version you keep choosing slowly wins more of your traffic, and once it's clearly ahead, four times out of five, it gets the job for good. you never touch a setting. you type, and the better model wins.

the menu stopped looking like a 1998 control panel. we designed it properly this time: a green dot when typer's on, red when it's not, a clean bar showing which model's ahead, switches instead of checkmarks, and every knob you never touch folded away until you go looking for it. the emoji confetti is gone.

two honest notes. the part that learns your exact style on-device is paused while we rebuild it on the new model. it's coming back, and it'll be better, trained on the preferences the race is collecting from you right now. and this is still alpha, still 100% on your Mac, nothing ever leaving the building. the [changelog](https://github.com/frgmt0/typer/blob/main/CHANGELOG.md) has the real wiring.

## 2026-06-18 — typer has a model of its own now

for as long as typer has existed it's been running on gemma — a genuinely good 3.5 GB model, but a general one, doing a job it was never trained for. so we trained our own. typer-1 does exactly one thing, finish the sentence you're in the middle of, and it's small enough that it's already quietly handling a slice of your suggestions as you read this.

on our own held-out test it keeps pace with gemma word-for-word. the difference is everywhere else: it gets the first word onto your screen in 35ms instead of 163ms, and it takes 386 MB on disk instead of 3.5 GB. that's the kind of thing you feel before you'd ever think to measure it.

it doesn't barge in, either. typer-1 starts on about a tenth of your suggestions and earns more only while it's keeping up with gemma on the words you actually take — and the second it starts slipping, gemma steps back in on its own. there's nothing for you to switch or tune.

the part we keep grinning about: the whole thing trained on a laptop, under a gigabyte of memory, and it survives you closing the lid mid-run. that's also what makes it personal from here — every suggestion you accept is now tagged to the model that wrote it, so typer-1 is already collecting the one thing it needs to start sounding like you specifically, with gemma underneath the whole time as the safety net.

still alpha, still nothing ever leaves your Mac. the [changelog](https://github.com/frgmt0/typer/blob/main/CHANGELOG.md) has the wiring if you want it.

## 2026-06-09 — typer started learning you, and stopped guessing

the two loudest complaints about typer turned out to be the same complaint wearing two coats: the suggestions felt random. so this whole update is about one thing — typer earning the right to be on your screen instead of just showing up.

the biggest change is that the model now tells us how sure it is, and anything it's only half-guessing at never appears at all. we measured it: the good completions came in at 0.27 and up, while the junk — the "use a ." nonsense — sat around 0.20. the bar lives at 0.22, right in the gap, so the junk dies quietly and you never see it.

underneath that, typer is paying attention to you. it keeps a little local table of the words you actually reach for and nudges the model toward them. it watches what you take and what you wave off — grab a word or two at a time and the suggestions get shorter to match; ignore most of what shows up and the bar tightens on its own. it even keeps separate notes for chat, email, and docs, because the way you talk in iMessage is not the way you write a doc, and pretending otherwise made everything worse.

two smaller things that were quietly driving people up the wall: pasting with `cmd+v` used to freeze the ghost on top of whatever you'd just pasted — it now ducks out the instant you paste and rebuilds from what's really in the field. and the ghost keeps up with fast typing now, because the app tells typer the exact moment a key lands instead of letting it guess.

all of it lives on your Mac and clears with one click, same as always.

## 2026-06-09 — typer got faster in a way you can feel

this is the kind of update with nothing new to learn — it just feels quicker. the model used to re-read your entire context on basically every pause; in an 800-keystroke test it now re-reads 12 times instead of 800, so its effort goes into the words you just typed instead of the ones it already knew about.

a few things came with that. hammering `tab` used to occasionally tab you clean out of the text field mid-sentence, which is about as rude as software gets — typer now holds the key for a beat while the next chunk loads, so tab always means "more," never "goodbye." after you take a whole suggestion, the next one starts generating in about 60ms instead of sitting through the full typing pause. and accepting a run of words used to drift the ghost slightly right of your cursor every time; it snaps back where it belongs now.

one more: clicking to place your cursor no longer summons a suggestion out of nowhere. typer just refreshes what it knows and waits for you to actually type something.

## 2026-06-02 — one giant file became twenty tidy ones

small confession: typer's menu-bar app was a single 2,487-line Swift file. it now lives in [scripts/typer/](https://github.com/frgmt0/typer/tree/main/scripts/typer) as one file per concern — completions, caret, event taps, config, stats, all of it. not a single thing changed about how typer behaves; this was purely us making the place nicer to live in.

if you've ever thought about poking around the code, this is the moment. it's readable now, and the "PRs welcome" line is not a bit — we mean it.

## 2026-05-30 — spell-fix now works in Discord, Slack, and VS Code

typo correction had a genuinely embarrassing habit in Electron apps: you'd accept a fix for `peopel` and end up with `peoplepeopel`. turns out those editors quietly ignore the accessibility API while swearing they support it. typer now checks whether its fix actually landed and falls back to plain honest keystrokes when an app lies to it — backspace the exact length, type the correction, put your cursor back where it was. boring and correct, which is the whole goal.

finishing a misspelled word with `space` will surface the fix now too, even with a suggestion already on screen. typo correction is still off by default while we sand down the edges — flip it on in the menu if you're feeling brave.

## 2026-05-30 — typer can remind you of what you just read

this is a new opt-in thing we're a little in love with: topic memory. every few minutes typer takes a quiet look at your focused window with on-device OCR, keeps just the gist — a name, a product, a one-line note — and files it locally. later, when you start typing "those Sony headphones i saw earlier," the detail is already there waiting in the suggestion.

the thing we care about is what it doesn't keep. never the raw screen text, just the distilled note, and it only ever speaks up when a distinctive word you read actually shows up in what you're typing. it skips terminals, secure input, and battery-saver mode, and Reset All Data wipes it like everything else.

it's off by default since it needs Screen Recording permission. menu → context sources → "remember what i read" if you want it.

## 2026-05-30 — a day spent shaving milliseconds

no headline today, just a pile of small things that add up. the helper stopped replaying around 1,024 tokens of prompt through the sampler on every single request. hot-path disk reads and per-keystroke log writes are gone. speculative prefetch now yields politely to your actual typing instead of racing it. and roughly 120 lines of dead code left the building.

also — and this one's good — the menu-bar icon could previously render at zero width, which is to say, be completely invisible. it's a keyboard symbol with your accepted-word count next to it now. you would be amazed how long you can ship an invisible icon before anyone mentions it.

## 2026-05-30 — we found the battery drain. it was us. sorry

profiling showed idle typer sitting at around 60% CPU. it wasn't the model — it was our own event tap stuck in a re-enable loop, having a very fast, very pointless argument with macOS about whether it should be awake. we fixed it. idle CPU went from 60% to 0%.

while we were in there: the debounce was actually shorter than the gap between keystrokes, so typer was running inference on nearly every character you typed. it now waits out a burst of typing and generates once. and on battery or Low Power Mode it automatically eases off — longer pauses, no speculative prefetch — which the menu will tell you when it's doing. your fans should stay quiet until you've genuinely earned the noise.

## 2026-05-29 — the ghost grew up

a real pass on the thing you stare at all day. the ghost text is drawn with Core Animation now — sitting on your caret line, tapering softly at the edge, with a one-shot shimmer when a fresh suggestion lands — and it's done lagging behind or overlapping what you're typing.

it also stays out of your way more carefully than it used to. the event taps were rebuilt so typer only ever holds onto a keystroke while a suggestion is actually showing; no suggestion, no interference, your typing never waits on us. accepted words get typed as a synthesized keystroke, so your clipboard stays yours. and you can switch typer off in specific apps, skip terminals entirely, or wipe everything from the menu whenever you want a clean slate.

## 2026-05-29 — we asked a reviewer to attack typer. it found things

we ran an adversarial security review across the whole pipeline and fixed everything it turned up. the short version: typer now goes completely inert during macOS secure input — password fields, `sudo`, password managers — no buffer, no learning, no logging, nothing at all. logs are off by default, file permissions got strict (`0600`), and the clipboard reader skips concealed items like password-manager copies.

none of this changed how typer feels, which is exactly the point. local-and-private is a promise, and promises are worth auditing.

## 2026-05-29 — fewer random words, and your stats got fun

two unrelated things that both made us happy. first, a real sampling overhaul — a min-p sampler and tighter settings mean the suggestions wander into random-word territory far less often, and the overlay stopped flickering while you type straight through it.

second, and admittedly less important: the menu now tracks words completed, a daily streak, and your running total translated into books. accept enough suggestions and it'll cheerfully inform you that you've typed 0.3 Hobbits. did we need this? no. are we keeping it? absolutely.

## 2026-05-29 — hello! typer is public

first public release, and the thing everything above is built on: inline ghost-text suggestions right at your cursor, in nearly any app, streaming in word by word with the first one landing in about 80ms. `tab` takes a word, `` ` `` takes the whole thing, `esc` says no thanks — or just keep typing and the ghost follows along without regenerating.

it learns your voice locally, from a small on-device record of how you actually write, and you can clear it any time. your group chat and your codebase don't share a brain. and the whole stack is honestly small: one `./install.sh`, a little GGUF model, and llama.cpp, all running on your Mac, MIT-licensed, no account.

it's alpha and we won't pretend otherwise — caret placement in terminals and custom editors is still approximate, and quality rides on your model. but it's real, it's ours, and it's only getting better. [come watch](https://github.com/frgmt0/typer), or better, come help.
