# Typer Inference Performance Research Log

> **MEASURED (2026-06-20).** The full TTFT/TPS suite has now run on this M2 Pro across
> Qwen3 0.6B/1.7B/4B + Gemma-4-E2B, llama.cpp vs MLX, q8/f16, cold/warm-off/warm-on.
> Headline: warm TTFT is governed by KV prefix reuse (already implemented; now verified
> firing at ~0.67 reuse). **Qwen3-1.7B q8 on llama.cpp serves a warm first token in 27 ms**
> (vs 87 ms on MLX), well inside the 100 ms budget; even 4B clears it (57 ms). q8 beats f16
> on speed and size. Decision: ship 1.7B q8 on llama.cpp, do not migrate to MLX. Full
> writeup with charts: `web/research/posts/2026-06-20-the-latency-budget-of-on-device-autocomplete.md`
> (live at typr.frgmt.xyz/research). Raw cells: `bench/results/*.json`; rerun: `bench/run_suite.sh`.
> The estimates below are superseded by those measurements where they conflict.

Status: **research log, not yet benchmark-confirmed.** Scope: maximize decode throughput
(TPS) and minimize time-to-first-token (TTFT) for the on-device autocomplete model behind
`scripts/llama_server.cpp`. TTFT is the binding product constraint; TPS is secondary.

Every flag, API, and source line below was checked against the local llama.cpp clone at
`~/.cache/typer-build/llama.cpp` (commit `32e806b`), the installed mlx-lm
(`training/.venv`, mlx-lm 0.31.3 / mlx 0.31.2), and the current server source. Numbers
that could not be measured on this hardware are marked **UNVERIFIED**: no public Qwen3
M2 Pro llama.cpp/MLX head-to-head benchmark was found, so every TTFT/TPS magnitude here is
either source-derived or bandwidth-extrapolated, not measured. The benchmark protocol in
the last section is what turns these into load-bearing numbers.

Host of record: Apple M2 Pro, 16 GB unified, macOS 26.4 (build 25E246). Primary dev box.
Must also stay sane on M1 / 8 GB base.

---

## 1. Objective

Two metrics, ranked:

1. **TTFT (the product constraint).** A persistent helper generates the next ~7 words as
   ghost text whenever the user pauses. If the first ghost token does not land within
   ~100 ms, the user has typed past it and the suggestion is wasted. TTFT is measured as
   the time from request-write to the first ghost-text byte on the helper's stdout.
2. **Decode TPS (secondary).** Throughput for the remaining ~7-12 tokens bounds when the
   *whole* suggestion is on screen. It matters, but a fast first token with a slow tail
   still feels responsive; a slow first token never gets seen.

Memory and battery are constraints, not objectives: this is an always-on background
process on a 16 GB (sometimes 8 GB) machine.

Model targets, autocomplete only, max 4B: **Qwen3-1.7B (PRIMARY)**, Qwen3-4B (ceiling),
Gemma-3n-E2B (experimental on-device "e2b"). Current shipped model is Qwen3-0.6B
(`typer-1-raw.gguf` / `typer-1-distill.gguf`, 639 MB each). Quantization preference is
**lossless-ish**: fp16 or q8_0, with q4_K_M only if quality holds. Quality is verified
*after* speed, never optimized here.

---

## 2. The incremental-prompt insight (why prefix/KV reuse is the dominant TTFT lever)

Typer's workload is not a normal chat workload. Each keystroke-pause, the prompt is a
large, mostly-unchanged context prefix (a few hundred chars) plus a handful of **new**
tokens, after which we decode only ~7 words. Consecutive requests differ by ~1-15 tokens.

That shape changes which lever matters. In a one-shot chat call, prefill cost is paid in
full every time and is a fixed tax. In Typer's stream, the prefix was already prefilled on
the *previous* keystroke. If we keep that KV state and only prefill the delta, prefill cost
collapses from O(full prompt) to O(new tokens):

- A 300-token context with a 295-token stable prefix means prefilling **5 tokens** instead
  of 300. Prefill TTFT drops by roughly the ratio of skipped tokens - a 5-50x TTFT
  reduction on warm requests, dwarfing every other knob.

This is why prefix/KV reuse is rank 1 and everything else is secondary. **The reuse is
already implemented** in `scripts/llama_server.cpp`:

- `prepare_prompt()` (lines 412-432) computes the longest common token prefix against
  `last_prompt_tokens`, calls `llama_memory_seq_rm(mem, 0, common, -1)` to evict only the
  diverged suffix, then decodes only the new tail. It deliberately re-decodes the final
  shared token (`common = min(common, toks.size()-1)`) so the logits correspond to the
  current prompt - this is correct and must not be removed.
- `stable_tail()` (lines 541-554) is the critical *enabler*. When context exceeds 2200
  chars it snaps the cut to a newline or sentence boundary instead of a raw byte offset, so
  the token sequence prefix is identical across keystrokes. Without it, the cut slides one
  byte per keystroke, the token prefix shifts, `common` collapses to near zero, and the
  entire rank-1 optimization silently dies.

The single most important verification in this whole effort: **confirm the reuse is
actually firing on a realistic keystroke replay** (common/len > 0.8), and **audit the
Swift client** to confirm it keeps a stable tail window and never kills/respawns the helper
between keystrokes (a respawn pays a 200-600 ms model reload that dwarfs all inference
tuning). The Swift client was not inspected in this research; this is open question #2.

---

## 3. Ranked lever table

Lane: which backend the lever applies to. Effort: implementation cost. All llama.cpp line
numbers refer to the current `scripts/llama_server.cpp`.

| # | Lever | Lane | Metric | Est. gain | Effort |
|---|-------|------|--------|-----------|--------|
| 1 | **Verify KV prefix reuse is actually firing** (instrument `prepare_prompt`) before touching anything else | both | TTFT | 5-50x TTFT on warm requests; this IS the dominant lever | low |
| 2 | `GGML_METAL_RESIDENCY_KEEP_ALIVE_S=3600` to prevent idle GPU-residency eviction | llama.cpp | TTFT | kills a 50-200 ms TTFT spike after >3 min idle; normal case unchanged | low |
| 3 | Stop the raw-vs-distill router interleaving models per keystroke during the race | llama.cpp | TTFT | removes a full reprefill on every model switch during the race phase | low |
| 4 | `n_ctx` 1536 -> 1024 (right-size KV allocation) | llama.cpp (mirror MLX) | memory | ~33% KV cut; <5% cold-prefill TTFT; battery win | low |
| 5 | Step the primary model 0.6B -> Qwen3-1.7B q8_0 | both | TPS/quality | large quality gain at ~1.83 GB; warm TTFT stays in budget if reuse is healthy | medium |
| 6 | Q8_0 KV cache (`type_k=type_v=Q8_0`, requires FA enabled) | llama.cpp | both | ~47% KV memory cut; 0-15% decode TPS; TTFT neutral | medium |
| 7 | Confirm/force Flash Attention enabled on Metal (AUTO -> ENABLED) and verify it engaged | llama.cpp | TTFT | 10-25% TTFT if FA was silently off; 0 if AUTO already enabled it | low |
| 8 | `n_ubatch` 512 -> 128 (right-size prefill dispatch buffer) | llama.cpp | memory | a few MB scratch; zero TTFT for sub-128 prefills | low |
| 9 | `n_threads` P-cores only (`n_threads=2`, `n_threads_batch=4`) | llama.cpp | both | 0.5-2 ms TTFT jitter; meaningful battery/thermal win | low |
| 10 | `swa_full` investigation for Gemma-3n-E2B only (ISWA prefix reuse) | llama.cpp | TTFT | potentially restores 5-50x reuse on Gemma-3n IF its SWA sub-cache blocks reuse; 0 for Qwen3 | medium |
| 11 | Speculative decoding (0.6B draft -> 4B target) - **defer; it HURTS TTFT** | both | TPS | ~1.4-1.5x decode TPS on 4B; +~13 ms TTFT; high integration cost | high |
| 12 | Full MLX backend migration (replace the C++ helper) | MLX | both | possible ~20-40% decode TPS at fp16 on the ceiling model; uncertain TTFT; high risk | high |

### Notes per lever

**1 - Verify reuse fires.** Highest leverage, near-zero effort. Add a stderr counter in
`prepare_prompt` printing `common` and `toks.size()` and confirm `common/len > 0.8` on a
realistic keystroke replay BEFORE changing any other knob. If it is not firing, no other
lever matters.

**2 - Residency keep-alive.** macOS 26.4 is confirmed on this box, so Metal residency sets
are active. ggml-metal's residency heartbeat stops after `keep_alive_s` seconds of
inactivity (default `3*60 = 180` s, `ggml-metal-device.m`). An always-on autocomplete
helper routinely idles longer than 3 minutes between typing sessions, so the next keystroke
pays a re-residency cost. Set the env var before `llama_backend_init()` (called in the
`LlamaEngine` constructor) or in the launch environment. Pure win, no quality risk. UNVERIFIED
magnitude - needs the idle-then-resume scenario to measure.

**3 - Router prefix-cache thrash.** Each model (`typer-1-raw.gguf`,
`typer-1-distill.gguf`) runs in its own subprocess with its own `last_prompt_tokens`. If
the `ModelRouter` alternates A/B on consecutive keystrokes during the graded-reward race,
each process misses its own prefix cache on the first call after a switch - a full
reprefill TTFT spike specific to Typer's current two-model-race architecture. Self-resolves
once the race locks at 80%, but during the race it is a real, measurable regression. Fix by
not interleaving per-keystroke (route per session, not per keystroke). Open question #5:
how often the router actually interleaves determines whether this is real or negligible.

**4 - n_ctx 1536 -> 1024.** `stable_tail` caps context at 2200 chars (~550 tokens) and
`max_words` is clamped to 32 (so output <= ~39 tokens after the harness adds slack); 1024
has ample headroom. One-line change at `n_ctx = 1536` (line 225). The overflow/truncation
path that clears `last_prompt_tokens` becomes effectively unreachable given the 2200-char
cap. Apply the same `n_ctx` to MLX for benchmark fairness.

**5 - 0.6B -> 1.7B q8_0.** 1.7B is the PRIMARY target. q8_0 (~1.83 GB) is the
lossless-ish default. The risk is purely TTFT: 0.6B already measures ~135 ms *cold* per the
`--check` flag, so a cold 1.7B will exceed 100 ms - but cold is the app-switch worst case,
not what users hit. The warm prefix-reuse TTFT (only delta tokens) is the product-relevant
number and should stay sub-budget if reuse is healthy. Must be validated by the protocol,
not assumed (open question #3). Note: the local `typer-1l.gguf` is 1.2 GB - between q4 and
q8 for a 1.7B - confirm its arch and quant via gguf metadata before trusting it as the
1.7B datapoint (open question #1).

**6 - Q8_0 KV cache.** Halves KV bandwidth on the memory-bound decode phase. Qwen3
`head_dim=128` is divisible by the Q8_0 block size 32, so the divisibility check
(`llama-context.cpp`) passes. **Requires Flash Attention ENABLED**, not just AUTO (V-cache
quant requires FA; context init returns null and the server crashes otherwise). The Metal
quantized-KV FA kernels carry a source comment "not optimized yet" - so the decode-TPS gain
at batch=1 is uncertain and could be neutral or slightly slower (open question #6). MUST
pass the KV-quant quality gate via `eval_compare.py` before shipping; KV quant subtly
shifts completions. Apply only to the *winning* weight quant, not every cell.

**7 - Flash Attention.** `cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO` is set
(line 254). With `n_gpu_layers=999` all Qwen3 layers are on Metal, so AUTO's device-match
check should enable FA. But log suppression (`llama_log_set` to a no-op at line ~239) hides
the confirmation. Temporarily unsuppress logs, run `--check`, and confirm
`flash_attn = enabled`. Forcing `LLAMA_FLASH_ATTN_TYPE_ENABLED` also unblocks lever 6. The
only real risk is a model that needs FA off, which AUTO already handles - so verify, then
force only if you need Q8_0 KV.

**8 - n_ubatch 512 -> 128.** With reuse working, incremental prefills are 3-15 tokens, far
below 512, so reducing `n_ubatch` only trims pre-allocated scratch with zero latency cost.
Keep `n_batch=512`. Align the `decode_tokens` chunk constant too. Pure memory hygiene.

**9 - n_threads P-cores.** Currently `max(2, hw_concurrency/2)` = 5 on a 6P+4E M2 Pro. With
full Metal offload the CPU only does the embedding `GET_ROWS` and host bookkeeping, so
fewer threads cut wake-time and scheduling jitter with negligible throughput cost. Keep
`>= 2` so the ~152K-vocab embedding lookup is not single-threaded. Battery matters here.

**10 - swa_full for Gemma-3n only.** `cp.swa_full = false` (line 255) is CORRECT and a
no-op for Qwen3 (`n_swa=0`, confirmed in `qwen3.cpp` - no sliding-window key loaded). But
Gemma-3n uses ISWA sliding-window layers, and `swa_full=false` *may* disable prefix caching
on the SWA sub-cache (llama.cpp PR #13194). This is an **untraced inference** (open question
#7): instrument `common>0` on Gemma-3n before flipping `swa_full=true` (which roughly
doubles SWA KV memory). Do NOT touch for the Qwen3 shipping path.

**11 - Speculative decoding.** Net-negative for the product constraint. Spec decoding
worsens TTFT (draft generation before the first verify) and only pays off on the slow 4B
ceiling, not the 1.7B primary. The custom JSONL binary has no spec loop, so it needs ~500
lines added or a backend migration. ngram-simple self-spec has near-zero TTFT penalty but
still needs the same integration work and only helps repetitive text. All Qwen3 dense
sizes share the tokenizer (vocab 151936), so 0.6B is a valid drafter - but Qwen3 dense has
no MTP heads, so `draft-mtp` is unavailable. Park until TTFT is fully optimized and only if
4B-for-TPS is ever pursued.

**12 - MLX migration.** Largest effort, most uncertain payoff, throws away a working
prefix-reuse implementation. See the MLX lane below for why this is parked.

---

## 4. The llama.cpp lane (shipping path)

Source-verified against commit `32e806b`. Current server settings (`LlamaEngine`
constructor): `n_gpu_layers=999`, `use_mmap=true`, `use_mlock=false`, `n_ctx=1536`,
`n_batch=512`, `n_ubatch=512`, `n_threads=n_threads_batch=5`, `flash_attn_type=AUTO`,
`swa_full=false`, `no_perf=true`, logs suppressed.

Findings:

- **Already optimal, do not touch:** full Metal offload (`n_gpu_layers=999`; input
  embedding layer intentionally kept on CPU - `llama-model.cpp` comment "very little benefit
  to offloading the input layer"); `offload_kqv` default true; `mmap=true`/`mlock=false`
  (correct for Apple unified memory - `mlock=true` would wire 1-3 GB unnecessarily);
  `swa_full=false` for Qwen3 (n_swa=0); FA AUTO (resolves to enabled with full offload).
  `defrag_thold` is deprecated and irrelevant for single-sequence use - omit it.
- **Cheap, no-quality-risk wins:** residency keep-alive (lever 2), n_ctx 1024 (lever 4),
  n_ubatch 128 (lever 8), P-core threads (lever 9). None change output; all reduce memory,
  battery, or tail-latency jitter.
- **Quality-gated wins:** 1.7B q8_0 weights (lever 5), then Q8_0 KV with FA forced ENABLED
  (levers 6+7), each behind `eval_compare.py`.
- **Weight-quant ladder (Qwen3-1.7B):** q4_K_M ~1.11 GB, Q6_K ~1.42 GB, q8_0 ~1.83 GB,
  bf16 ~3.45 GB. Decode is bandwidth-bound on the M2 Pro's ~200 GB/s, so smaller weights
  decode faster: at full bandwidth a single decode step reads the weights once, giving a
  theoretical TPS ceiling roughly inversely proportional to weight bytes (~181 t/s q4_K_M,
  ~109 t/s q8_0, ~59 t/s bf16; real-world ~50-70% of that). UNVERIFIED on this hardware.
  Prefer K-quants over I-quants on Metal: I-quants (IQ4_NL etc.) are documented as slower
  than K-quants of comparable size. Ship q8_0 if memory allows; q4_K_M only if the quality
  gate passes.
- **Gemma-3n-E2B:** fully implemented in this clone (`LLM_ARCH_GEMMA3N`, `gemma3n.cpp` with
  AltUp / Laurel / Per-Layer-Embeddings). The existing `gemma-4-E2B-i1-Q4_K_M.gguf`
  (3.5 GB) is already converted. Architecture caveats: ISWA hybrid cache with
  `n_layer_kv_from_start=20` (only 20/30 layers carry their own KV), and the AltUp 4-stream
  per-layer compute plus the large per-layer-embedding lookup make wall-clock TTFT likely
  *worse* than a vanilla 2B despite the "E2B" label. Treat as ceiling/experimental only.

The expected outcome of this lane: with reuse confirmed and the cheap wins applied, the
1.7B q8_0 warm-TTFT should sit inside the 100 ms budget. This is the shipping path.

---

## 5. The MLX lane (evaluated, parked)

Verified against mlx-lm 0.31.3 / mlx 0.31.2 in `training/.venv`.

MLX has real, native equivalents of every llama.cpp lever:

- **Prefix reuse:** `make_prompt_cache` + `trim_prompt_cache`, or the server's
  `LRUPromptCache` (trie-based longest-prefix match). Same 85-90% prefill saving on warm
  requests. The C++ `stable_tail` logic would have to be re-ported on the Python side; if
  the cut slides, reuse never fires here either.
- **Residency:** `mx.set_wired_limit()` pins weights GPU-resident across idle gaps
  (macOS 15+; this box is 26.4). Do it once at startup for an always-on helper, not just
  per-call.
- **Async overlap:** `generate_step` already uses `mx.async_eval` to overlap GPU work with
  Python sampling - no change needed in 0.31.3.
- **Quant:** q4 affine g64 (~968 MB for 1.7B), q8 (~1.83 GB), KV quant via `kv_bits=8`.
- **Spec decoding:** `draft_model=` + `num_draft_tokens` (0.6B drafting 1.7B/4B), same
  tokenizer family.

Why it is parked for the shipping path:

1. **The dominant TTFT lever already works in C++.** Qwen3 dense uses a plain trimmable
   KVCache so reuse fires reliably in both backends; migrating means re-porting working
   code for uncertain gain.
2. **The C++ in-process JSONL server already avoids IPC/HTTP overhead** and keeps the model
   resident - exactly what an always-on helper needs. MLX's clearly-faster path
   (`mlx_lm.server`) adds an HTTP layer; its in-process path costs a one-time graph-compile
   (~0.5-2 s, warm it with a dummy call at startup).
3. **Gemma-3n-E2B is a trap on MLX right now:** `mlx_lm.server` produces garbage output for
   it (issue #1384, fix PR #1396 unmerged) and sliding-window prefix reuse via
   `RotatingKVCache` is unreliable (issue #980). llama.cpp has a complete working ISWA path.

The one place MLX could win is the **Qwen3-4B ceiling on decode TPS** (commonly ~20-40%
faster Metal GEMV at fp16) - but that is the non-shipping ceiling, and TTFT (where
llama.cpp's mature reuse dominates) is the product constraint. Reconsider MLX only if the
protocol shows llama.cpp Metal systematically under-utilizing the GPU on decode AND TPS
becomes the binding constraint. Benchmark both before committing a rewrite.

---

## 6. Benchmark protocol

The full protocol lives in `bench/README.md` (how to run the two harnesses, the shared
results schema, the matrix, and the fairness rules). Summary of what makes a result
load-bearing:

- **Metrics:** TTFT p50/p95 (cold and warm reported *separately*, never blended); effective
  prefill tokens + tokens-skipped-via-reuse (so cache hit rate is visible); decode TPS;
  end-to-end suggestion latency p50/p95; peak RSS + unified-memory footprint; battery proxy
  (`powermetrics` cpu+gpu ms per suggestion); prefix-reuse hit rate
  (fraction with common/len > 0.8).
- **Scenarios:** cold process; warm with reuse OFF (honest worst case after an app switch);
  warm with reuse ON on a *synthesized incremental replay* of `typed_eval.jsonl` (the raw
  jsonl is independent prompts - you must replay each context as a growing prefix, +1-5
  tokens per step, or the warm numbers are meaningless); idle-then-resume (>3 min, to catch
  the residency-eviction spike).
- **Fairness:** same box / macOS / AC power / cooled thermal state; identical prompts and
  `max_words`; pinned `n_ctx` (1024) on both backends; measure TTFT at the same boundary
  (bytes-on-stdout for C++ vs first `stream_generate` yield for in-process MLX); N >= 50
  warm requests, discard first 2, report p50/p95 not mean. Treat llama.cpp q4_K_M vs MLX q4
  affine g64 as "comparable", not equal - report both file sizes.
- **Harness change required:** the C++ `--check` flag currently emits only
  `latency_ms` to stderr (`scripts/llama_server.cpp` line ~587). Extend it to emit
  `ttft_ms`, `prefill_tok`, `decode_tok`, and `tokens_skipped` as one JSON line so the
  harness reads one identical schema from both backends. This is a prerequisite, not an
  optional extra.
- **Quality check runs AFTER speed, never during,** via `eval_compare.py` on all 180
  `typed_eval.jsonl` prompts (field: `completion`). Gates: q8_0 within <=1% exact-match
  delta vs fp16 of the same model; q4 must hold an agreed floor; Q8_0 KV no regression vs
  F16 KV; `last_avg_prob` distribution unchanged so the UI's low-confidence suppression
  stays calibrated.

---

## 7. Expected winner

**llama.cpp for the shipping path on Qwen3-1.7B.** Three concrete, current-state reasons:

1. Typer's single biggest TTFT lever - token-level prefix reuse + `stable_tail` - is
   already implemented and working in the C++ binary (`prepare_prompt`, lines 412-432), and
   Qwen3 dense uses a plain trimmable KVCache so reuse fires reliably. On MLX the equivalent
   exists but you would re-port working code for uncertain gain.
2. The custom in-process JSONL server already avoids IPC/HTTP overhead and keeps the model
   resident - exactly the always-on shape. MLX's only clearly-faster path adds HTTP; its
   in-process path costs a one-time graph compile.
3. Gemma-3n-E2B is broken on MLX (issue #1384 / PR #1396 unmerged) but complete on
   llama.cpp.

The one caveat: for the Qwen3-4B **ceiling** where decode TPS outweighs TTFT, MLX's better
Metal GEMV at fp16 could win on TPS - but that is not the shipping path. **This expectation
is not yet load-bearing:** no verified Qwen3-on-M2-Pro number exists anywhere in this
research, so the protocol in section 6 must confirm it.

**Recommendation:** stay on llama.cpp; do NOT migrate backends or add speculative decoding
yet. Highest-leverage action: verify the reuse you already shipped is firing (instrument
`prepare_prompt`; confirm common/len > 0.8 on a realistic replay; audit the Swift client's
tail-window stability). Then take the cheap, no-quality-risk wins: residency keep-alive,
n_ctx 1024, n_ubatch 128, P-core threads, and stop the router interleaving models per
keystroke. With TTFT secured, step the primary model 0.6B -> 1.7B q8_0, then evaluate Q8_0
KV (FA forced ENABLED) gated on `eval_compare.py`. Run the protocol; warm prefix-reuse TTFT
p50/p95 on the real incremental stream is the verdict metric.

---

## 8. Open questions

1. Is `typer-1l.gguf` (1.2 GB) actually a Qwen3-1.7B-class model, and at what quant?
   1.2 GB is between q4 and q8 for a 1.7B. Confirm via gguf metadata before using it as the
   primary datapoint.
2. Does the Swift caller keep a STABLE tail window across keystrokes and never respawn the
   helper? `prepare_prompt`'s reuse is only as good as `stable_tail`'s output stability; a
   sliding byte offset on the Swift side collapses `common` and silently kills lever 1. The
   Swift client was not inspected.
3. What is the real warm-prefix-reuse TTFT for Qwen3-1.7B q8_0 on this exact M2 Pro? Every
   TTFT/TPS magnitude here is extrapolated; the 100 ms verdict for 1.7B is unproven until
   measured.
4. Does the `typed_eval.jsonl` replay represent the real keystroke distribution? The dataset
   is independent prompts; the true incremental stream (new tokens per pause, app-switch
   frequency) determines the real cache hit rate.
5. For the two-model race: how often does the router interleave A/B per keystroke vs per
   session? That decides whether lever 3 is a real regression or negligible.
6. Does Q8_0 KV on Metal (the "not optimized yet" quantized-KV branch) actually speed up
   decode at batch=1, or is it neutral/slower? Measure, do not assume.
7. Does Gemma-3n-E2B's ISWA path get prefix reuse under `swa_full=false` in llama.cpp, or is
   reuse silently disabled (forcing a full reprefill every keystroke)? Untraced inference;
   instrument `common>0` on Gemma-3n before flipping `swa_full`.

---

## FUTURE WORK (out of scope here)

**"typer-writer"** is a separate, explicitly-invoked (not ambient) local writing mode for
rewrite / draft / tone work, using a larger 4-8B model. It is a different product surface
with a different latency contract: a user who invokes a rewrite tolerates a spinner, so TTFT
is not the binding constraint there and decode TPS / quality dominate instead. That inverts
the priorities of this entire document. **typer-writer is explicitly out of scope for this
autocomplete speed work** and must not be conflated with the always-on ghost-text helper.
The levers that are net-negative here (speculative decoding, a 4-8B target, MLX's TPS
advantage at fp16) are exactly the ones worth revisiting *for typer-writer* when that effort
begins.
