REVIEWED BY PI AGENT | APPROVED

# Adversarial Review — Efficiency & Cleanup

**Scope:** `scripts/typer_native.swift` (2181 lines), `scripts/llama_server.cpp` (525 lines).
**Goal:** make Typer faster + lower-power; remove dead code; tidy the codebase.
**Status:** review only — **no code was changed.** Findings are ordered by impact.
Line numbers are at the time of writing.

---

## TL;DR

The recent battery work fixed the catastrophic idle spin (accept-tap mach loop) and
the per-keystroke inference storm. What remains are **steady-state hot-path costs** that
make typing heavier and slower than it needs to be:

1. **Disk read on every generation** — `style.txt` is read from disk (main thread)
   inside `assembledContext`, once per `generate()` and once per `maybePrefetch()`.
2. **File open→write→close per log line, several times per keystroke** — the always-on
   `log()` is called on the caret/AX hot path; most of those should be `dlog` (gated).
3. **Redundant modifier tracking → the observer tap wakes on every key *release*** —
   `keyUp` interest + `setModifier` + 4 booleans duplicate what `event.flags` already
   carries. Dropping them halves observer-tap callbacks.
4. **C++ per-token shaping is O(context) per token** (`remove_echo` back-off loop +
   double `first_line_clean`), and `make_sampler` replays the *entire* prompt through
   `llama_sampler_accept` when only the last 64 tokens matter.
5. A worst-case **400-iteration synchronous AX query loop** in caret fallback.
6. A pile of **dead code** (7 unused functions, ~5 write-only fields).

The single biggest *latency* lever remains the model itself (same 3.2GB Gemma-4-E2B as
Cotypist) — see §3.

---

## 1. Swift hot-path performance

### 1.1 `style.txt` is read from disk on every generation  ⭐ high
- `StyleMemory.sample(maxChars:)` does `try? String(contentsOf: url)` (line **465**)
  every call.
- It's called from `assembledContext(immediate:)` (line **1680**), which runs in
  `generate()` (line **1196**, main thread) and `maybePrefetch()` (line **1127**, main
  thread).
- Net: a synchronous read of up to `maxBytes = 40_000` (line 437) on the main thread
  **per generation and per prefetch**.
- `sentenceCount()` (line **479**) re-reads the same file on every `rebuildMenu()`.
- **Fix:** cache the file contents (or the derived sample) in memory; invalidate on
  `record()` / `clear()`. `StyleMemory` already serializes writes on a queue, so an
  in-memory mirror is straightforward. Removes all hot-path disk reads.

### 1.2 Always-on `log()` does open/seek/write/close per call, on the typing path  ⭐ high
- `log()` (lines **15–26**) calls `fileExists`, opens a fresh `FileHandle`, `seekToEnd`,
  writes, and closes — **every call**. There are **39** always-on `log()` sites vs only
  6 `dlog()` (gated) sites.
- Several fire on the hot path, multiple times per keystroke/generation:
  - `textAroundCursor` → line **1907** (per `generate()`).
  - `caretPoint` → line **1947**, plus `boundsForSelectedRange` → lines **2051, 2056,
    2063, 2069, 2078, 2083** (per caret read; `scheduleReanchor` triggers a caret read
    ~0.05s after each follow-along keystroke).
- So normal typing incurs ~2–4 file open/write/close cycles per keystroke on the main
  thread.
- **Fix:** (a) reclassify hot-path diagnostics (`AX text context…`, `caret point…`,
  `AX caret …`, `AX bounds unavailable…`) as `dlog` (off by default). (b) Keep a single
  long-lived `FileHandle` for the log instead of reopening per line. (c) Optionally move
  writes to a serial utility queue so logging never blocks the event path.

### 1.3 Observer tap wakes on every key *release* for redundant state  ⭐ high
- `observerMask` includes `keyUp` (line **765**) solely so `setModifier` (lines
  **825/827/936**) can maintain `shift/cmd/ctrl/alt` booleans.
- The only reader is line **849**: `if hasCommandLikeModifier || cmd || ctrl || alt`.
  But `hasCommandLikeModifier` (line **829**) is derived from `event.flags` of the *same*
  keyDown and already covers Command/Control/Option. The `|| cmd || ctrl || alt` is fully
  redundant; `shift` is never read at all (write-only).
- **Fix:** delete `setModifier`, the four booleans, drop `keyUp` from `observerMask`, and
  simplify line 849 to `if hasCommandLikeModifier { return }`. This **halves
  observer-tap callbacks** (no keyUp wakeups) on the global typing path and removes a
  source of drift (manual state can desync from reality; `flags` cannot). Pure win.
- Note: keep `kVK_*` modifier *keycodes* used elsewhere; only the tracked-state machinery
  is redundant.

### 1.4 Worst-case 400 synchronous AX queries in caret fallback  ⭐ medium
- `boundsForSelectedRange` step 5 (lines **2074–2082**) scans backward up to 400
  positions, each doing a parameterized `AXBoundsForRange` IPC call, synchronously on the
  main thread, until one succeeds.
- Apps that fail steps 1–4 (some Electron/custom views) can hit the full 400-call loop →
  a multi-tens-to-hundreds-of-ms main-thread stall during caret placement.
- **Fix:** cap the scan far lower (e.g. 24–40) and/or step in larger increments; the
  marginal benefit of landing exactly on a far-back line is low.

### 1.5 `rebuildMenu()` does directory + file I/O off the suggestion/accept path  ⭐ low–medium
- `rebuildMenu` calls `MLXClient.findModel` (directory enumeration, line **669**) and
  `styleMemory.sentenceCount()` (disk read, line **675**).
- It is invoked not just on menu-open (correct, via `menuNeedsUpdate`) but also from
  `show()` (line **1700**), `showTypoIfMisspelled` (line **1343**), `acceptOneWord`
  (1743), `acceptAll` (1770/1780).
- Completion accept (`acceptCompletionWord/All`) correctly does **not** call it, so the
  common path is spared; the cost lands on the typo/grammar paths (off by default). Still
  redundant — `menuNeedsUpdate` already rebuilds lazily on open.
- **Fix:** drop the `rebuildMenu()` calls from `show`/accept paths; rely on
  `menuNeedsUpdate` + `updateStatusTitle()` for the live badge. Combined with §1.1 this
  removes disk I/O from suggestion display entirely.

### 1.6 Minor allocations
- `numberFormatted` (lines **2109–2112**) allocates a `NumberFormatter` per call (×~4
  per `funFacts()` per menu rebuild). `markActiveToday` (line **2099**) allocates a
  `DateFormatter` per accept. Both are cheap and off the hottest path; cache as `static`
  if touched. Low priority.

---

## 2. C++ helper (`llama_server.cpp`) performance

### 2.1 Per-token shaping is O(context) per token  ⭐ medium–high
- The streaming callback (lines **478–503**) runs, for **every generated token**:
  - `first_line_clean(full)` at line **480**, *and again* inside `shape()` at line
    **468** — `first_line_clean` runs ~9 `cut_marker` find-loops + `strip_html_tags`
    twice per token.
  - `remove_echo` (lines **198–215**) whose back-off loop (lines **210–214**) does up to
    ~107 `std::string::find` passes over the output **per token**, scaling with context
    length.
- For a 14-token completion that's on the order of ~1.5k string scans, all on the
  generation thread, growing with prompt size — added latency per streamed word.
- **Fix:** (a) compute `first_line_clean(full)` once per token and pass it into `shape`.
  (b) Skip `remove_echo` for *partial* frames (cosmetic only); apply it once to the final
  `raw` in `shape(raw)` at line **507**. (c) Cap `remove_echo`'s back-off length.

### 2.2 `make_sampler` replays the whole prompt through `accept`  ⭐ medium
- Line **307**: `for (auto tok : prompt_tokens) llama_sampler_accept(chain, tok)` accepts
  *all* prompt tokens (up to ~1024) into the sampler chain on every request.
- The only stateful sampler is `penalties` with `penalty_last_n = 64` (line **301**), so
  only the last 64 tokens can possibly affect sampling. Accepting the other ~960 is wasted
  work on the request-setup path.
- **Fix:** accept only the last `min(prompt.size(), 64)` tokens.

### 2.3 Per-token batch allocates 5 vectors in the gen loop  ⭐ low
- The single-token decode in `generate()` (lines **385–386**) calls `decode_tokens`,
  which allocates 5 `std::vector`s per call (lines **315–319**).
- **Fix:** use `llama_batch_get_one(&id, 1)` for the single-token step, or keep a reusable
  pre-sized batch. Saves a handful of small allocations per generated token.

### 2.4 Header hygiene (low)
- Verify `<cstring>` / `<sstream>` are actually used; drop if not. Cosmetic.

---

## 3. The biggest latency lever: the model

Generation tokens/sec and first-token latency are model-bound. Typer ships the **same**
`gemma-4-E2B-i1-Q4_K_M.gguf` (3.2GB) Cotypist uses, full-GPU-offloaded
(`n_gpu_layers = 999`, cpp line 233), `n_ctx = 1024` (line 223). The KV prefix-reuse in
`prepare_prompt` (lines 337–358) is good and already minimizes prefill while typing
(the changing `immediate` text is appended last, so its stable prefix is reused).

Options to make it *feel* faster without hurting quality, in rough order of value:
- **Smaller/faster generation model** (e.g. a 0.5–1B causal model) as an option/default —
  the only lever that raises tokens/sec. Quality trade-off; a product decision.
- **Speculative decoding** with a tiny draft model (llama.cpp supports it) — keeps the 2B
  quality with lower latency, at the cost of bundling a draft model + more code.
- **Trim prompt for chat boxes:** `assembledContext` (lines 1677–1688) prepends style
  (≤300 chars) + background (≤700 chars) when `immediate < maxImmediateForBackground`
  (220). That's ~250–300 extra tokens to prefill for short fields; consider shrinking the
  background cap, since prefill dominates first-token latency there.

A benchmark harness that reports **energy + latency per accepted suggestion** (not raw
latency) would let the reviewer decide §3 on data. The `--check` path (cpp lines 430–438)
already measures single-shot latency and could be extended.

---

## 4. Dead code to remove

### Unused functions (definition is the only reference)
| Symbol | Line | Notes |
|---|---|---|
| `focusedWindowBounds()` | 1457 | never called; comment even references the removed `CGWindowListCreateImage` |
| `replacePreviousWord(with:)` | 1806 | never called (typo path uses `replaceWordBeforeSeparatorViaKeys`) |
| `selectedOrWordRect()` | 2018 | never called |
| `textBeforeCursor(limit:)` | 1911 | never called (callers use `textAroundCursor`) |
| `testCompletion` / `testTypo` / `testGrammar` | 2087–2089 | `@objc` debug stubs, not wired to any menu item |

### Write-only / dead fields
| Symbol | Line | Notes |
|---|---|---|
| `generationSerial` | 582 | incremented at 1013, **never read** |
| `shift` | 576 | set in `setModifier`, **never read** (see §1.3) |
| `acceptedWords` | 575 | only ever set to 0 (1341, 1727), never incremented/read |
| `pendingTypoElement` / `pendingTypoRange` | 585/586 | only ever set to `nil` (1363/64, 1728/29); never assigned a real value or read |
| `TyperStats.ignored` | 491 | never incremented; only decoded for back-compat (510). Keep the decode for old files but it can drop out of the live struct/UI |

Removing §1.3's modifier machinery also deletes `setModifier` (936) and the `cmd/ctrl/alt`
fields (577–579).

**Estimated cleanup:** ~120–160 lines of Swift removable with zero behavior change.

---

## 5. Correctness-adjacent observations (not asked, flag-only)

- `boundsForSelectedRange` runs on the main thread via `caretPoint()` and is fairly AX-IPC
  heavy on fresh suggestions; §1.4 is the acute case but the whole function is worth
  profiling on Electron apps.
- `assembledContext` re-derives the style sample every generation (tie-in with §1.1);
  caching also makes the prompt prefix more stable → better KV reuse in the helper.
- `withPasteboard` / typo keystroke path (lines 1374–1383, 1821–1845) uses `usleep` on the
  caller thread; only reachable with typo correction enabled (off by default), so not a
  current hot path, but note it blocks whatever thread calls it.

---

## 6. Suggested order of operations for the implementer

1. **§1.3** (drop keyUp + modifier state) and **§4** (delete dead code) — pure, safe,
   mechanical; shrinks the file and cuts tap callbacks.
2. **§1.1 + §1.2** (cache style sample; demote hot-path `log()` to `dlog` + persistent
   handle) — removes per-keystroke disk I/O. Biggest steady-state CPU/energy win.
3. **§1.5** (stop rebuilding the menu off the suggestion path).
4. **§2.1 + §2.2** (helper per-token shaping + sampler accept window) — lowers per-word
   generation latency.
5. **§1.4** (cap the AX scan).
6. **§3** — discuss model strategy / build a per-suggestion energy+latency benchmark before
   changing the default.

Each item is independently shippable and individually measurable (idle CPU, `powermetrics`
energy, and the helper `--check` latency number).
