# Review: Cotypist-parity overhaul (working tree)

Read-only review of the uncommitted overhaul. Severities below are the
adversarially-verified ratings, which in several cases differ from the
original reporter's first-pass severity (noted inline where downgraded).

---

## Executive summary

The overhaul compiles green and is structurally sound: AXSafe timeouts, the
ladder-based caret placement, the watchdog/crash telemetry, and the model
router all hold together, and no critical memory-safety, persistence-corruption,
or feedback-loop defect was found. The headline problems are of two kinds:

1. **Main-thread blocking IPC on the completion hot path.** Token budgeting was
   regressed from pure in-memory string assembly into synchronous helper
   round-trips on the main thread (`tokenCount()` inside `budgetedContext()`).
   This is the exact "freezes while typing" class the AXSafe/D.1 work exists to
   prevent, reintroduced on the LLM path.
2. **An Office-freeze regression on the caret path.** `AXEnhancedUserInterface`
   is re-asserted on every caret re-anchor for flagged apps (Word/Outlook) with
   no set-once guard — a known Office main-thread stall vector.

Beyond those, a cluster of W2/W4 wishlist features are **fully implemented but
never wired in** (emoji completion, typo-suspicion gate, the personalization
logit-bias map) and two **Settings toggles are silent no-ops that visibly bounce
back**. None of these are default-on, so they are dead features and acceptance-
criteria failures rather than active regressions — but two of them ship live UI
controls that do nothing.

### Gripe-area readouts

- **Caret placement: HAS GAPS.** The primary inline path is solid. The
  TextMirror fallback path — which is a **shipped default for Google Docs**
  (`textMirroringEnabled` is on for `docs.google.com`) — is half-wired: it
  double-renders the suggestion (mirror ghost + inline ghost overlapping) and
  mis-places the caret whenever there is more than ~one line of text before the
  cursor (it feeds up to ~4000 chars into a one-line window). For the common
  Google Docs case the mirror caret is systematically wrong. The inline path is
  fine; the mirror fallback needs fixes before it can be trusted.
- **AX anti-freeze coverage: ONE REAL HOLE.** The AXSafe 50ms read timeout is
  correctly applied and bounds wedged-host *reads*. But it does **not** bound an
  outbound AX *write*, and `applyEnhancedUserInterfaceIfNeeded()` re-issues the
  `AXEnhancedUserInterface` SET on every re-anchor for Office apps — re-opening
  the exact freeze the overhaul targets. Separately, the LLM token-budget path
  blocks the main thread on helper IPC, which is outside AXSafe's scope
  entirely. Anti-freeze is solid for reads, holed for the EUI write and the
  budgeter IPC.

---

## VERDICT

**(a) Commit to the branch: YES, after the must-fix list below.** The tree is
coherent and the defects are localized; nothing here is a landmine for other
work on the branch. But two of the must-fix items (EUI re-set, main-thread
token budgeting) are genuine regressions of the overhaul's own stated goals and
should not be committed as "done" without being addressed or explicitly ticketed.

**(b) Daily-drive: NOT YET.** Do not daily-drive until the two HIGH main-thread/
freeze items and the two visible-no-op Settings toggles are fixed. Typing in
Word/Outlook (EUI re-set) and any helper slowness (budgeter IPC) can stall input
up to ~1.5s, and Google Docs caret placement is wrong on the default mirror path.

---

## Must-fix before commit

1. **Token budgeting blocks the main thread** (`LlamaClient.swift:247-274`,
   reached from `TyperApp+Completion.swift:448/329`) — move off-main or
   char-estimate on the sync path.
2. **`AXEnhancedUserInterface` re-set every re-anchor** (`TyperApp+Caret.swift:484-489`)
   — add a per-pid set-once guard.
3. **Settings toggles are silent no-ops** (`TyperApp+Menu.swift:215-240`) —
   add `setToggle` cases for `show_suggested_fixes` and
   `suppress_completion_on_typo_suspected` (visible bounce-back on a live UI control).
4. **TextMirror double-renders + mis-places caret** (`TyperApp+Caret.swift:399-422`,
   `TextMirror.swift:72-83`) — these are on a **default-on** Google Docs path,
   so they are user-visible out of the box. Gate the inline overlay on
   `mirrorActive` (or revert the mirror to a pure rect-locator) AND feed only a
   small window around the caret.

## Fix-soon

- Emoji completion (#7) never invoked (`TyperApp+Typo.swift:453`) — dead feature.
- Typo-suspicion gate (#8) never consulted (`TyperApp+Typo.swift:419-426`) — dead
  feature behind a live (but no-op) toggle.
- `tokenCount` timeout can kill a still-loading helper (`LlamaClient.swift:228-243`).
- Budgeter mixes real counts with char-estimates, defeating KV reuse
  (`LlamaClient.swift:255-268`).
- `maybeOfferRecommendedModel()` fires pre-onboarding (`LetsMove.swift:30-33`).
- Crash signal handler does async-signal-unsafe Swift work (`TyperApp.swift:519-538`).
- `InlinePrediction.clearRecord()` not called by Reset All Data
  (`InlinePrediction.swift:72-77`) — spec G violation.

## Nice-to-have

- Hot-path AX efficiency: `currentWebHost()`, host-font double-read,
  EUI/host-override lookups all run per placement for all apps
  (`TyperApp+Caret.swift:304, 59-60/262-279/381`).
- Personalization logit-bias map dead-ended (`TyperApp+Completion.swift:129-160`).
- Mirror end-of-text caret one glyph left; FIM suffix UTF-8 split; FIM suffix
  echo not stripped; prefetch loses FIM suffix.
- Watchdog `mainBeat` data race; `ModelDownloader` field race.
- Dead APIs: `caretPathByBundle`, PID polling-suspension, `openInlinePredictionCard()`.
- Disk-precheck reverts to hardcoded `'s'` instead of prior tier
  (`TyperApp+Model.swift:67-68`).
- AX per-element registrations accumulate within one app session
  (`TyperApp+AXObserver.swift:90-105`).

---

## Findings by severity

### HIGH

**H1 — Token budgeting blocks the main thread on helper IPC**
`LlamaClient.swift:247-274` (reached from `TyperApp+Completion.swift:448`, `:329`)
`budgetedContext()` calls `tokenCount()` synchronously; on a cache miss it does
`start()` + pipe write + `readResponseLine(timeoutMs:1500)` — a blocking helper
round-trip. Both callers (`generate()`, `maybePrefetch()`) run `assembledContext()`
on the **main thread**, before their off-main dispatch (`generate()` is fired from
the debounce Timer). `immediate` (the live before-cursor text) changes every
generation, so it is an unavoidable cache miss → at least one blocking round-trip
per generation on the main run loop. The `lock.try()` lowPriority skip does NOT
save the foreground path (no request holds the lock at that point, so it takes the
blocking branch). Under any helper slowness this stalls input up to 1.5s.
*Note: original report flagged this as critical for "every keystroke / always 1.5s";
verified as HIGH — generation is debounce-gated (fires on pauses, not per char) and
the idle-case tokenize is fast (the 1.5s is a worst-case ceiling for a degraded helper).*
**Fix:** move `assembledContext`/`budgetedContext` token measurement onto the
existing background queue before `request()`, OR char-estimate on the sync path and
refine async, OR never measure `immediate` via the helper (always a miss) — estimate
it. At minimum drop the budgeting timeout to a few ms with a guaranteed char fallback.

**H2 — `AXEnhancedUserInterface` re-set on every caret re-anchor (Office freeze vector)**
`TyperApp+Caret.swift:484-489` (called from `:371`)
`applyEnhancedUserInterfaceIfNeeded()` issues
`AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface", true)`
unconditionally — no read-before-write, no set-once guard — for flagged apps
(Word/Outlook, `AppOverrides.swift:80/82`). It is on the placement hot path
(re-anchor on AX notifications, scroll, completion render). Toggling EUI forces
Office to (re)build its AX tree synchronously; re-asserting it per re-anchor is the
documented Office main-thread stall. The 50ms AX read timeout does NOT bound an
outbound SET. *Severity high (scoped to two override apps, single same-thread call).*
**Fix:** track enhanced pids in a `Set<pid_t>` on `CaretState`, set once per app,
reset on app termination / pid change so a relaunch re-enables.

**H3 — TextMirror feeds ~4000 chars into a one-line window → caret mis-placed**
`TyperApp+Caret.swift:399-422`, `TextMirror.swift:72-83/130-153`
`mirrorCaretRect` passes `textAroundCursor(limit:2000)`, so `text = before + after`
can be ~4000 chars with `caretIdx` up to ~2000. `present()` sizes the window/view to
a **single line**, but `update()` sets the text container height to
`.greatestFiniteMagnitude`, so the text wraps into many fragments.
`caretRectInMirror()` returns the wrapped fragment's `minY` (hundreds of points down),
so the mapped screen rect lands far below the visible one-line window while the
window only shows the top of the layout. The mirror is the designated fallback for
Google Docs and AX-hostile fields, so for any field with more than ~one line of
preceding text (the common case) the caret/ghost is systematically misplaced.
**Fix:** pass only a small window around the caret (recomputing `caretIdx`), or size
the mirror to the laid-out content height and clip/scroll to the caret's line fragment
before mapping to screen.

### MEDIUM

**M1 — TextMirror double-renders the suggestion (default-on for Google Docs)**
`TyperApp+Caret.swift:399-422`, `TyperApp+Completion.swift:228-231`, `TextMirror.swift:52-96`
When the mirror path is active (`textMirroringEnabled` default-on for
`docs.google.com`), `mirrorCaretRect()` passes `suggestion = completion?.remainder`
into the mirror, which renders the ghost itself (alpha 0.5). But `caretPoint()` still
returns a screen point and `showCompletionRemainder()` unconditionally calls
`overlay.showCompletion(...)`. The `mirrorActive` flag is read only by
`dismissMirrorIfActive()` — nothing suppresses the inline overlay. Result: the
suggestion is drawn twice, overlapping inside the mirror window. Spec defined the
mirror's `update()` without a `suggestion:` parameter (pure caret-rect locator); the
impl diverged by baking the ghost in without gating the inline render.
*Original report: high; verified medium — cosmetic double-ghost, no crash/corruption.*
**Fix:** gate `showCompletionRemainder` on `!caretState.mirrorActive` (mirror is sole
renderer), OR revert the mirror to spec (no baked suggestion) and keep only the inline
overlay.

**M2 — Settings toggles for fixes / typo-gate are silent no-ops that bounce back**
`TyperApp+Menu.swift:215-240`
`setToggle`'s switch has no case for `show_suggested_fixes` or
`suppress_completion_on_typo_suspected`, so both hit `default: return` — cfg is never
mutated, nothing persisted. `SettingsModel.setToggle` then calls `load()`, snapping the
@Published switch back to its old position (visible bounce). Both cfg fields ARE
consumed (`TyperApp+Typo.swift:165, 420`) and round-trip in the parser
(`TyperConfig.swift:157-158`), so the controls are intended to work.
*Correction to original report: the three emoji/mid-line keys it also named are NOT
bound to any UI control, so only these two are real defects. Severity high→medium.*
**Fix:** add `setToggle` cases for both keys (set the cfg field, fall through to
`writeConfig`), mirroring the existing pattern.

**M3 — `tokenCount` timeout can terminate a helper that is still loading the model**
`LlamaClient.swift:228-243`
`start()` returns immediately after `p.run()` while the helper is still loading the
GGUF (the C++ side only reads stdin after the model-load constructor completes,
`llama_server.cpp:662/674`). If budgeting runs in the cold-start window, the tokenize
write succeeds but `readResponseLine(timeoutMs:1500)` times out during load, and the
catch does `process?.terminate(); process = nil` — killing the helper mid-load; the
next real `request()` must respawn and reload, compounding the stall. A 4B GGUF makes
`>1500ms` load likely. No warmth gate exists.
**Fix:** don't terminate the helper from a best-effort tokenize timeout — return the
char estimate and leave the process alone; better, gate budgeting on the helper being
warm and fall back to estimates otherwise.

**M4 — Budgeter mixes real token counts with char-estimates, defeating KV reuse**
`LlamaClient.swift:255-268`
`tokenCount()` returns a real cached count on a hit but a `~4-chars/token` estimate when
`lock.try()` fails or on IPC error, and the estimate is never cached. A block straddling
the budget boundary can be KEPT one generation and DROPPED the next for identical context
(depending on lock timing), changing the prompt prefix bytes and defeating `prepare_prompt`
value-match KV reuse — the very stability the comment claims. The persistent driver is
`immediate` (never cached), whose `spent` baseline oscillates under contention.
**Fix:** make keep/drop a pure function of block strings — skip an uncached block (or cache
the estimate too) rather than re-measuring with timing-dependent values.

**M5 — `maybeOfferRecommendedModel()` fires before onboarding (double model prompt)**
`LetsMove.swift:30-33`, `TyperApp.swift:169` vs `:190`
`maybeOfferMoveToApplications()` runs before `showOnboarding()`. For the common
already-in-/Applications case it hits the early branch and calls
`maybeOfferRecommendedModel()`, which on a fresh launch (default variant `'s'`) pops the
"A better model fits your Mac" alert BEFORE the onboarding model picker — and
self-suppresses (UserDefaults flag), so it never re-shows in context. Confusing
pre-onboarding download prompt, then onboarding asks again.
**Fix:** gate the recommendation on `cfg.onboardingComplete`, or move it into a
post-onboarding hook.

**M6 — Crash signal handler does async-signal-unsafe Swift work**
`TyperApp.swift:519-538`
The `@convention(c)` handler for SIGSEGV/SIGABRT/etc. calls `String.withCString` on
string literals and `crashBundleBuffer.withUnsafeBufferPointer` (Array access goes through
a `swift_once` lazy-init thunk + ARC retain/release). Under a heap-corruption SIGSEGV or a
runtime lock held at fault time, this can deadlock or re-fault before the re-raise,
suppressing the OS crash report it exists to preserve. (The bundle-id capture into a static
buffer + `write(2)` is already safe; `strlen` IS async-signal-safe, contrary to the
original note.) Opt-in (`cfg.debugLogging`), so impact is bounded.
*Severity medium/low — diagnostic-only path; OS crash report doesn't depend on these writes.*
**Fix:** pre-render prefix + bundle id + newline into a fixed `CChar` buffer at record time,
and in the handler do only `write(2, ptr, precomputedLen)` + `signal(SIG_DFL)` + `raise()`.

### LOW

**L1 — Emoji completion (#7) is fully implemented but never invoked**
`TyperApp+Typo.swift:453` — `maybeHandleEmoji(_:)` has zero call sites; `handleTyping()`
(`TyperApp+EventTap.swift:260-316`) never calls it. `:shortcode:` / emoticon expansion and
`:prefix` search never fire; the ~47KB dataset is unreachable. Gated behind
`emojiCompletionsEnabled` (default false), so it's a dead opt-in feature / acceptance-
criteria failure, not a regression. *Original report: high; downgraded to low/medium —
default-off, no user-facing breakage.*
**Fix:** in `handleTyping()` after `appendToBuffer(text)`, `if maybeHandleEmoji(text) { return }`.

**L2 — Typo-suspicion gate (#8) never consulted**
`TyperApp+Typo.swift:419-426` — `typoSuspectedInCurrentWord()` has zero callers; `generate()`
never invokes it. Toggling `suppressCompletionOnTypoSuspected` has no effect; completions
still extend misspelled words. Live (but no-op, see M2) Settings control. Default false.
*Original report: high; downgraded — opt-in, default-off.*
**Fix:** in `generate()` after the snooze/enabled guards,
`if typoSuspectedInCurrentWord() { clearSuggestion(); return }`.

**L3 — Personalization logit-bias map dead-ended**
`TyperApp+Completion.swift:129-160` — `personalizationBiasMap()` has no caller;
`leadingTokenIDs(of:)` hard-returns `[]`, so `PersonalizationBias.biasMap` is always empty;
no wire path consumes a `[Int32:Float]` map (only the lexicon STRING channel, which IS live).
Documented as a deferred W4 seam. No runtime impact (default strength 0). Worth flagging so
the bias map isn't mistaken for shipped.
**Fix:** wire `LlamaClient.tokenIDs(_:)` end-to-end and consume the map, OR delete the dead
scaffolding and document the lexicon-string path as the sole interim mechanism.

**L4 — `InlinePrediction.clearRecord()` not called by Reset All Data (spec G violation)**
`InlinePrediction.swift:72-77` — `clearRecord()` is documented as "registered in resetData()"
but `resetData()` (`TyperApp+Menu.swift:409-433`) never calls it. After "Turn it off for me"
+ Reset All Data, the prior-value record orphans in UserDefaults; a later `turnOffForMe()`
won't re-record an updated prior value, so an uninstall-time restore can write back a stale
global `NSAutomaticInlinePredictionEnabled`. Dead method + false doc comment.
**Fix:** add `InlinePrediction.clearRecord()` to `resetData()` alongside the existing clears.

**L5 — Disk-precheck failure reverts model choice to hardcoded `'s'`**
`TyperApp+Model.swift:67-68` — on an `m→l` switch where the `'l'` disk pre-check fails,
`cfg.modelVariant` is reverted to `'s'` (not the prior `'m'`), silently downgrading a
working medium model. Recoverable (the `'m'` file isn't deleted).
**Fix:** capture the prior `cfg.modelVariant` at entry and revert to it.

**L6 — `currentWebHost()` AX window-walk runs on every placement for all apps**
`TyperApp+Caret.swift:304` — `caretRect()` eagerly evaluates `currentWebHost()` (3-4 AX
round-trips: focused element + AXWindow + AXURL + title/NSDataDetector) as an argument even
for native apps, on the re-anchor hot path. Each read is bounded by the 50ms AXSafe timeout,
so it's efficiency, not correctness. *Original report: medium; verified low.*
**Fix:** gate on browser bundles and memoize per focus session (invalidate on focus/scroll).

**L7 — Host-font AX read happens 2x per placement and isn't actually cached**
`TyperApp+Caret.swift:59-60, 262-279, 381` — `currentHostFont()`'s comment claims a per-
descriptor cache, but the AX `AXAttributedStringForRange` read runs on every focused
placement (cache is fallback-only); and `currentCaretPoint()` does the read twice (font +
caret-height). All bounded by AXSafe, so latency not correctness. Spec mandated a
descriptor-keyed cache that was never implemented. *Original report: medium; verified low.*
**Fix:** read `(font,color,height)` once per focus session and reuse for both overlay font
and caret-height derivation.

**L8 — `AXEnhancedUserInterface` write on the hot path (efficiency facet of H2)**
`TyperApp+Caret.swift:484-489` — same root as H2; listed once. The correctness/freeze risk is
covered under H2; the per-placement write is also wasteful AX I/O.

**L9 — Legacy `caretPathByBundle` is write-only dead state**
`TyperApp.swift:52`, written at `TyperApp+Caret.swift:321/326`, never read. Ordering now runs
off `caretState.ladderPathByBundle` (and the same winner is recorded via `recordLadderPath`),
so the marker-vs-bounds preference is preserved — no regression, just dead writes + an unused
property. *Correction: original "silently lost the preference" framing is wrong; preference is
preserved.*
**Fix:** drop the two assignments and the property.

**L10 — Mirror caret at end-of-text is one glyph too far left**
`TextMirror.swift:72-83` — the clamp to `numberOfGlyphs-1` plus `location(forGlyphAt:)` returns
the leading edge of the last char when the caret is at end-of-text with no suggestion/after-text.
Only triggers with an empty ghost; cosmetic, mirror path only.
**Fix:** when `cursorPosition >= numberOfChars`, use the line-fragment used-rect maxX (or last
glyph location + advancement / don't clamp the `location` call).

**L11 — FIM final output runs `remove_echo` against prefix only; can leak duplicated suffix**
`llama_server.cpp:744/807-814`, `TyperApp+Completion.swift:531-533` — FIM post-processing strips
prefix echoes but not suffix overlap; the Swift repeat-drop guard only catches a head-prefix of
`lastTrailing`, so a completion re-emitting the suffix at its tail/mid-string survives both guards.
Gated behind `fim_available()` (infill-token GGUF) — dormant for the Qwen3-0.6B base. *Original
report: medium; verified low — non-default model path, cosmetic.*
**Fix:** strip a trailing overlap against the suffix, or pass the suffix into the C++ shaper.

**L12 — Mid-line prefetch loses the FIM suffix**
`TyperApp+Completion.swift:321-351` — `maybePrefetch()` calls `request(...)` with no `suffix:`, so
a prefetch promoted while mid-line is a plain continuation that can duplicate trailing text;
aggravated by `promotePrefetch()` bypassing the repeat-drop guard.
**Fix:** thread `fimSuffix` into `maybePrefetch` and pass `request(suffix:)`, or suppress prefetch
while mid-line.

**L13 — FIM suffix byte-truncation can split a UTF-8 sequence**
`llama_server.cpp:713` — `suffix.resize(600)` cuts at a raw byte offset (Swift caps at 400
characters ≈ up to ~1600 bytes), so a split multibyte char becomes a byte-fallback token in the
suffix region. Inconsistent with `utf8_safe()`. Harmless to stability; mildly degrades conditioning.
**Fix:** walk back over `0x80` continuation bytes after resize.

**L14 — Budgeter uses arm A's tokenizer even when generation runs on arm B**
`TyperApp+Context.swift:486-489` — budgeting uses `router.client(for:.a)` but `router.pick()` may
return arm B with a different vocab. Latent under the shipped same-family race (both arms share the
Qwen3 tokenizer); only manifests if the model glob matches two different-vocab models AND a long
block straddles the boundary.
**Fix:** budget against the selected client (move budgeting after `pick()`), or reserve headroom
larger than any plausible A/B delta.

**L15 — Watchdog `mainBeat` is a cross-thread data race**
`TyperApp.swift:151` (written `:475` main Timer, read `:483` watchdog queue) — plain `Int`, no
atomic/lock. UB per the memory model, but aligned-Int loads aren't torn on arm64; worst case is a
spurious/missed log line. Opt-in (debugLogging). (`watchdogLastBeat`/`watchdogStalls` are
queue-confined and NOT racy, contrary to the original note.)
**Fix:** post the increment onto `watchdogQueue`, or use an atomic.

**L16 — `ModelDownloader` shared fields mutated across queues without a lock**
`ModelDownloader.swift:29-79` — `destination`/`expectedBytes`/`onDone` written by `download()`
(caller thread) and `finish()` (delegate queue, `delegateQueue: nil`). The `isDownloading` gate
makes the window small; real race per the memory model, low impact.
**Fix:** confine the fields to one queue or guard with a lock.

**L17 — AX per-element notifications accumulate within one app session**
`TyperApp+AXObserver.swift:90-105` — `refreshObservedElement()` deliberately never removes the prior
element's `kAXValueChanged`/`kAXSelectedTextChanged` (D.2: removing on a dead element can hang), so a
long-lived app with heavy focus churn accumulates stale registrations until pid teardown.
*Correction: the original "re-anchors against a non-focused element" claim does NOT hold — the
re-anchor reads the system's CURRENT focused element, so stale fires re-anchor correctly (just
redundantly). It is unbounded cheap-registration growth, not a geometry bug.*
**Fix (optional):** when swapping elements and the previous is still alive, remove its notifications;
accept non-removal only for dead elements.

**L18 — `openInlinePredictionCard()` (menu re-open) never wired**
`InlinePrediction.swift:235-237` — spec #4 asks for a card PLUS a menu warning to re-surface it;
the re-open method has no caller, and the card auto-shows only once. No recovery path if dismissed.
**Fix:** add a `MenuPopover`/`SettingsWindow` row gated on `clashActive()` that calls it.

**L19 — PID polling-suspension API is dead code**
`Admissibility.swift:57-70` — `suspendPolling`/`isPollingSuspended`/`clearPID` have no callers; the
per-PID set is never populated, so the mechanism provides no behavior (the per-bundle backoff IS
wired and works). Unfulfilled Cotypist-parity scaffolding.
**Fix:** wire it into the capture path, or remove the dead API.

---

## Summary counts

- HIGH: 3 (H1 budgeter main-thread IPC, H2 EUI re-set, H3 mirror caret mis-placement)
- MEDIUM: 6 (M1 mirror double-render, M2 no-op toggles, M3 helper kill on load,
  M4 KV-reuse defeat, M5 pre-onboarding prompt, M6 unsafe crash handler)
- LOW: 19
- **Must-fix before commit: 4** (H1, H2, M2, and the M1+H3 mirror pair on the
  default-on Google Docs path)
