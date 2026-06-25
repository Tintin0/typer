# Launch announcement — DRAFT

> Status: **DRAFT.** Every feature claim below is sourced from `docs/impl-contract.md`
> (shipped decisions) and the existing `ANNOUNCEMENTS.md` entries (measured numbers).
> Deferred items — the multi-candidate suggestion picker and a Sparkle/notarized DMG —
> are teased as "coming," never claimed as shipped. Do a final reconciliation pass against
> the real build (`scripts/typer/*.swift`, `CHANGELOG.md`) before publishing.

---

## long-form (announcements.md entry)

### 2026-06-24 — typer, the local-first autocomplete that lands where you actually type

typer is autocomplete for your whole Mac, running entirely on your Mac. a dim suggestion appears at your caret in almost any app — tab takes the next word, backtick takes the rest, esc dismisses — and the text never leaves the machine. no account, no cloud call, no telemetry. the model is a GGUF file on your disk and llama.cpp is doing the work. that's the whole deal, and it's the part we will never trade away: the core completion engine is free, MIT, and fully local, forever.

the thing we're proudest of in this release is unglamorous and hard: the ghost text now lands on your real caret almost everywhere. native AppKit fields were always easy. the rest of the Mac is not. so we built an ordered fallback ladder that tries the precise thing first and degrades gracefully — accessibility caret bounds for native apps, text-marker bounds for Chromium and Electron, then a TextKit "mirror" that re-renders your line off-screen and asks the layout engine for the exact glyph rect when an app won't tell us where the caret is, then our screenshot-and-read path for GPU terminals and custom editors, and finally a click-anchor that slides with your typing. the part Cotypist doesn't have: we can find the caret by reading the screen, so terminals, canvas editors, and Google Docs get a ghost that sits in the right place instead of nowhere. and we read the host app's real font over accessibility now, so the suggestion is the right size in the right typeface — which is also what killed the drift you used to see during fast typing.

under that is a lot of plumbing you'll only notice because nothing breaks. context capture got leaner — we read a thin band around your caret line instead of whole windows. and stability got the real work: every accessibility call is wrapped with a 50 ms messaging timeout so a slow or wedged app can't freeze typer, the screen observer releases on a deferred path so it can't deadlock, and secure input is hard-walled — password managers are always suppressed, and the moment you're in a secure or password field, typer goes silent. IDEs and apps with their own autocomplete are off by default too, but you can flip any of them back on per app if you'd rather have typer there.

then the quality-of-life layer, the stuff that makes it yours. per-app custom instructions, so typer writes one way in your terminal and another in your email. a snooze that turns completions off for the next few minutes — or off in just the front app — when you need the room. a completion-length control from a single word up to a full thought. a personalization-strength dial that biases suggestions toward the words you actually use (this round it's a logit-bias map built from your own high-frequency words, computed locally — no training, no adapter leaving your disk). emoji completion from shortcodes with skin-tone and gender variants. suggested-fix styling that flags a likely typo distinctly from a normal suggestion, with a gate so a typo doesn't quietly become a wrong completion. and guidance for macOS's own inline prediction, with a one-click opt-in write that records your prior text so you can always undo.

picking a model is friendlier now too. there's a catalog you choose from by your machine, with disk-aware downloads that won't start a pull you don't have room for. the lineup, by time-to-first-token on an M2 Pro: typer-1s at 0.6B for the tightest machines, typer-1m at 1.7B with first word on screen in 27 ms, and typer-1l at 4B in 57 ms — both comfortably under the ~100 ms budget where ghost text still feels instant. (q8 turned out faster than full precision and half the size, so that's what we ship.) and if you ran typer straight out of the download, it'll quietly offer to move itself into /Applications so updates and permissions behave.

honest about the edges, because alpha is alpha. the click-anchor fallback follows a single line, so if you click into a no-caret-API app and type a full wrapping paragraph, placement can lose the thread until your next click — single-line chat boxes, which is most of where it matters, are solid. a couple of things are still on the bench, not in the build: a multi-candidate picker so you can flip through more than one suggestion, and a signed, auto-updating DMG so install isn't a git clone. both are coming; neither is here yet.

install is one line today:

    git clone https://github.com/frgmt0/typer && cd typer && ./install.sh

it runs on llama.cpp, needs macOS 14+, and stays on your Mac. that's the point. the [changelog](https://github.com/frgmt0/typer/blob/main/CHANGELOG.md) has the engineering.

---

## Show HN blurb (short)

**Show HN: typer — local-first autocomplete for any macOS app (llama.cpp + GGUF, no cloud)**

typer puts a dim ghost suggestion at your caret in almost any Mac app — tab for the next word, backtick for the rest. it runs entirely on-device on llama.cpp; no account, no cloud, no telemetry, MIT-licensed, and the core engine stays free and local forever.

the hard part we focused on is caret placement everywhere, not just native fields: an ordered fallback ladder (accessibility bounds → text-marker bounds for Electron/Chromium → an off-screen TextKit mirror → screenshot/OCR → click-anchor) plus reading the host app's real font, so the ghost lands in the right spot and the right typeface across native apps, web/Electron, terminals, and Google Docs. reading the screen to find the caret is something comparable tools don't do, and it's what makes terminals and canvas editors work.

also in: leaner context capture (a band around the caret line, not whole windows), real stability hardening (50 ms accessibility timeouts so a wedged app can't freeze us, deferred observer release, hard secure-field/password-manager suppression), and a QoL set — per-app instructions, snooze, completion-length, a local personalization dial, emoji, typo-fix styling, inline-prediction guidance with opt-in write, a hardware-aware model catalog with disk-aware downloads, and move-to-/Applications.

speed, by time-to-first-token on an M2 Pro: 1.7B in 27 ms, 4B in 57 ms, both under the ~100 ms feels-instant budget.

still coming, not yet shipped: a multi-candidate picker and a signed auto-updating DMG. today it's `git clone && ./install.sh`, macOS 14+.

https://github.com/frgmt0/typer

---

## tweet-length

typer: local-first autocomplete for any macOS app. a dim ghost lands on your caret — tab the next word, backtick the rest — running fully on-device on llama.cpp. no cloud, no account, MIT. caret placement that works in native apps, electron, terminals & google docs. 1.7B first word in 27ms. git clone && ./install.sh
