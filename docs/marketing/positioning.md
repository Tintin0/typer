# typer — positioning & go-to-market

The one job of this doc: keep the story honest and consistent across the site, the
announcements, HN/Reddit/PH copy, and any future offering. It is the source of truth for
*what we say* the same way `docs/impl-contract.md` is the source of truth for *what we ship*.

Tone everywhere: all-lowercase, terse, first-person-builder, anti-hype. real measured
numbers only. one exclamation max. admit the rough edges. (the `ANNOUNCEMENTS.md` header
is the canonical voice spec — follow it verbatim for any public copy.)

---

## 1. one-line positioning

> **autocomplete that never leaves your Mac.**

the spoken-aloud version, when people need the reference point:

> **Cotypist, but open and yours.**

what each half is doing:
- *never leaves your Mac* — the whole pitch in five words. on-device, no account, no cloud.
- *open and yours* — MIT source you can read and rebuild; the model and your learned style
  are files on your disk that you own and can delete.

supporting sub-line (homepage already uses a version of this):

> local autocomplete for macOS. a dim suggestion appears at your caret in almost any app,
> on your Mac and nowhere else.

---

## 2. the moat (do not betray this)

the open-source + local-first promise **is** the product's reason to exist. it is the one
thing the closed competitors structurally cannot copy without cannibalizing themselves.

hard rules for every offering, every page, every launch:
- the core completion engine is **always free and fully local.** forever.
- anything hosted/Pro/Team is an **additive convenience** that **degrades gracefully to
  fully-local.** if our servers vanish, the app still works exactly as before.
- no dark patterns. no gating core function behind an account. no telemetry-by-default.
  no "free trial that nags." the local build is not a crippled demo of a paid product —
  it is the product.

if a proposed feature can't satisfy all four, it doesn't ship.

---

## 3. target users

three concentric rings, roughly in order of who we win first.

**ring 1 — privacy-literate mac power users.** the people who already moved to local LLMs,
ollama, little snitch, a password manager with a denylist. they don't want their keystrokes
in someone's training set. they will read the source. they are the HN/r/macapps/r/LocalLLaMA
crowd and our first and loudest advocates. this is who we write the homepage for.

**ring 2 — developers and heavy writers in mac-native + electron apps.** people typing all
day in notes, mail, slack, terminals, IDEs, obsidian. they feel the speed (first word well
under ~100ms) and the type-into-the-suggestion flow. autocomplete that's everywhere, not
locked to one editor, is the hook.

**ring 3 — the privacy-constrained-by-policy.** legal, medical, finance, anyone under an NDA
or a compliance regime that forbids sending text to a cloud. for them "on-device, source you
can audit" isn't a preference, it's a requirement. this ring is also the natural future home
of a Team/managed-config offering.

who we are explicitly **not** chasing: people who want a turnkey cloud SaaS and don't care
where their text goes. that's the existing closed market; competing there abandons the moat.

---

## 4. trust / privacy proof-points

these are concrete and verifiable — that's the point. don't claim privacy as a vibe; show
the mechanisms. every claim below maps to real behavior in the app (see `README.md` Privacy
section and `docs/impl-contract.md` D.3/D.4).

- **everything runs on-device.** llama.cpp + a small GGUF model on your machine. no account,
  no Apple Developer Program, no network call to make a completion.
- **password-manager denylist (always on).** completions are hard-suppressed in 1Password,
  Apple Passwords, Bitwarden, Dashlane, LastPass, KeePassXC, Proton Pass, and the rest — not
  a setting you can forget to flip.
- **secure-field skip.** secure text-field role/subrole detection plus
  `IsSecureEventInputEnabled()` — password fields, the login window, `sudo`, secure web
  fields: no buffering, no learning, no logging, no generation.
- **the log is not a keylogger.** by default it records counts and events, never typed text.
- **your files are yours.** learned style and stats live under
  `~/Library/Application Support/typer/` at mode `0600`. clear learned style / reset all data
  from the menu, any time.
- **own-autocomplete & IDE suppression by default** (overridable per-app) so we never fight
  the editor you already trust.
- **the caret edge competitors lack.** typer places ghost-text in **terminals and
  custom-drawn editors** via a ScreenCaptureKit + Vision OCR caret locator, on top of the
  AX + TextMirror ladder used for native/web/Electron. all of that runs locally. this is a
  genuine capability advantage, not just a privacy story — lead with it when the audience is
  technical.
- **auditable.** MIT. read it, rebuild it, change it. nothing is hidden because nothing can be.

framing rule: pair every privacy claim with the mechanism. "no cloud" is cheap; "completions
are suppressed in password fields by role detection, always on, here's the code" is trust.

---

## 5. the open-core offerings ladder

every rung is opt-in and degrades to the rung below it. rung 0 is the product; everything
above it is convenience. this is how we monetize without betraying the moat (mirrors spec
section I).

**rung 0 — free local core. forever.** the completion engine, all models, learned style,
per-app context, typo correction, the compatibility coverage. MIT, build from source. this
is never gated, never degraded, never sunset.

**rung 1 — hosted appcast + signed/notarized binaries (opt-in convenience).** for people who
don't want to install Xcode CLI tools + Homebrew and build. a notarized download + auto-update
feed. the source build is always available and always free; this just saves a step.
degrade: turn it off and you're back to `./install.sh` + `./update.sh`, identical app.

**rung 2 — opt-in cloud distillation that returns a local LoRA.** local KTO personalization is
the default and always works offline. if you opt in, you can upload *your own* accepted-
completion logs, we train a better personal LoRA in the cloud (faster than your laptop can),
and you **download it back and run it locally.** the cloud is a faster oven; the bread is
still baked and eaten on your machine. degrade: never opt in and local training is unchanged.

**rung 3 — Pro conveniences.** per-app custom-instruction management, multi-candidate picker
polish, priority model hosting/mirrors, nicer settings sync. the same Plus/Pro split Cotypist
uses — but the core engine the Pro features sit on top of is still free and local. nothing in
Pro is required to get great completions.

**rung 4 — Team / managed config (later).** shared per-app instruction packs and denylists
for orgs, managed settings, SSO for the admin console. we manage **settings, never content** —
no org's keystrokes pass through us. this is the natural offering for ring 3 (compliance).

selling principle: we charge for *convenience and scale*, never for *the core capability or
your privacy*. a user who pays nothing and builds from source must get a first-class product.

---

## 6. public compatibility matrix

a `/compatibility` page (net-new; see recon — Agent C owns it) that turns the internal caret
fallback ladder into an honest, public per-app table. this is exactly what Cotypist does, and
it builds trust precisely *because* it admits what's rough.

columns (per app / app-class): caret placement method (AX marker / AX bounds / TextMirror /
OCR / click-anchor), completion quality, known quirks, status (solid / approximate / known
issue). cover at least: native AppKit (TextEdit, Notes, Mail), WebKit/Electron (slack,
vscode, chrome inputs), terminals (Terminal, iTerm, GPU terminals), google docs, and the
default-suppressed IDEs.

rules:
- **be honest.** "approximate caret in GPU terminals" stays on the page until it's actually
  fixed. the page is a trust instrument; a dishonest matrix is worse than none.
- use the existing research-page table idiom + shared color tokens (green = solid,
  accent = approximate, red = known issue) so it reads native to the site.
- keep it current with the ladder in `docs/overhaul-spec.md` §B as caret support lands.

it doubles as our best SEO surface (people search "<app> autocomplete macos") and our best
contributor magnet ("this app is approximate — here's the file, send a PR").

---

## 7. SEO & launch channels

**positioning keywords to own:** "local autocomplete macos", "on-device text prediction mac",
"open source autocomplete", "private autocomplete", "cotypist alternative", "autocomplete for
terminal macos", "<specific-app> autocomplete macos" (long-tail via the compatibility matrix).

**site SEO basics:** real titles/meta per page; the compatibility matrix as the long-tail
landing surface; research posts (grounding, latency-budget) as credibility/backlink anchors;
the announcements feed for freshness. link the homepage to `/compatibility`, `/research`,
`/announcements`, and GitHub.

### channels, in order

**1. Show HN.** the primary launch. angle: *"Show HN: typer — open-source, on-device
autocomplete for macOS (no cloud, runs on llama.cpp)."* lead with privacy + the terminal/OCR
caret capability competitors lack, then the compatibility matrix as the honesty signal. HN
rewards (a) it's genuinely open and you can run it now, (b) real measured numbers
(first word well under ~100ms), (c) admitting alpha rough edges. be in the thread to answer.
have the repo, the matrix page, and a short demo ready before posting.

**2. r/macapps + r/LocalLLaMA (+ r/apple if it lands).** r/macapps is the home audience: lead
with "free, MIT, runs entirely on your Mac, here's the menu-bar demo." r/LocalLLaMA cares
about the model story (Qwen3-0.6B base, local KTO, your-own-LoRA distillation) — lead there
with the on-device model + personalization-without-cloud angle. no marketing voice; talk like
a builder sharing a thing, because we are.

**3. Product Hunt.** secondary, for reach beyond the dev crowd. tagline: "autocomplete that
never leaves your Mac." emphasize the everywhere-not-one-editor angle and privacy for the
broader audience; the technical depth is less the hook here than the "it just works in any
app and nothing leaves your machine" promise.

**4. evergreen / long-tail.** the compatibility matrix and research posts keep pulling
search traffic between launches; each new app we add to the matrix is a small SEO event and a
reason to post a one-line announcement.

launch-copy guardrail: every channel uses the same honest frame. no rounding a vibe into a
statistic, no "revolutionary", one exclamation max. the credibility *is* the marketing.

---

## 8. messaging cheat-sheet (lift these verbatim)

- headline: **you type the first half, it shows you the rest.**
- one-liner: **autocomplete that never leaves your Mac.**
- reference: **Cotypist, but open and yours.**
- proof in one breath: *runs on llama.cpp + a local GGUF model. no account, no cloud,
  password fields skipped, source on GitHub.*
- footer tagline (live): *free, forever · MIT · runs on llama.cpp · macOS 14+*
- the one thing competitors can't say: *it works in your terminal too, and none of it leaves
  your machine.*
