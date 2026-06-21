---
slug: latency-budget-on-device-autocomplete
title: "The Latency Budget of On-Device Autocomplete: llama.cpp vs MLX at 0.6B to 4B"
date: 2026-06-20
authors: The Typer Project
abstract: >
  Typer's autocomplete must place ghost text on screen before the user types past it, a
  budget of roughly 100 ms to the first token. This report measures time-to-first-token
  (TTFT) and decode throughput for Qwen3 at 0.6B, 1.7B, and 4B, plus Gemma-4-E2B, across
  two inference backends (llama.cpp and Apple's MLX) on an M2 Pro, under the workload that
  actually occurs: an incremental prompt that grows by a few tokens per keystroke. The
  central result is that warm TTFT is governed almost entirely by key-value prefix reuse,
  not by raw model speed. With reuse working, a 1.7B model serves a warm first token in
  27 ms on llama.cpp, comfortably inside budget, and even a 4B model clears it at 57 ms.
  llama.cpp wins TTFT at every size by a wide margin because its in-process prefix reuse
  and low per-call overhead beat MLX's, while MLX leads raw decode throughput at the
  larger sizes. Quantization to q8 is faster than fp16 in addition to being smaller, so
  fp16 buys nothing here. We also document why the newest published models (Qwen3.5,
  Gemma 4) do not yet fit this path: they are multimodal hybrids whose architecture our
  inference stack does not support for the dense, prefix-reuse text workload. The decision
  is to ship a 1.7B at q8 on llama.cpp and not migrate backends.
---

## 1. The constraint is latency, not quality

A personal autocomplete is judged first by whether it is there when you pause. The model proposes the next few words as grey ghost text the instant you stop typing; if the suggestion arrives after you have already typed the next word, it is worse than nothing, because it flickers and distracts. The governing quantity is therefore time-to-first-token (TTFT): the wall-clock interval from "user paused" to "first ghost-text character on screen." Our working budget is about 100 ms, the rough threshold below which the suggestion feels like it was already there rather than computed in response.

This reframes a question we had been asking incorrectly. We had been treating model size purely as a quality dial and assuming that a larger model is categorically out of reach on-device. The honest question is narrower: for each model size, does the warm first token arrive inside the latency budget? Decode throughput (tokens per second after the first) matters too, because it bounds when the whole seven-word suggestion finishes, but it is secondary. A model that streams quickly but takes 200 ms to start is useless for ambient ghost text. A model that starts in 30 ms and streams at a moderate rate is not.

## 2. The workload is an incremental prompt

The detail that makes on-device autocomplete unusual, and that dominates everything below, is the shape of the prompt. Typer does not send an independent prompt per request. As you type, the prompt is a large and mostly unchanged context prefix followed by a few new tokens, then the model decodes a short continuation. Between one keystroke-pause and the next, almost the entire prompt is identical.

This means the expensive part of inference, the prefill of the prompt into the key-value (KV) cache, is almost entirely redundant work that a correctly built server can skip. If the server retains the KV cache of the previous prompt and reuses the longest common token prefix, each new request only prefills the handful of genuinely new tokens. TTFT then collapses from "prefill the whole context" to "prefill three tokens and emit one." The size of this effect is the difference between a usable and an unusable product, so we measure it directly rather than assume it.

To exercise it honestly the benchmark does not feed independent prompts. It replays each evaluation context as a growing prefix, starting at 40% of the text and appending a few tokens per step, so consecutive requests share a long common prefix exactly as live typing does. We report three scenarios: a cold process (model load and first prefill, the one-time startup cost), a warm process with reuse disabled (the honest worst case after an application switch or a large edit invalidates the cache), and a warm process with reuse enabled (the steady-state keystroke case, which is what a user actually experiences).

## 3. Method

We benchmark two backends against the same realistic prompts (the 180-example typed set from the prior report) on a single M2 Pro with 16 GB of unified memory, on AC power, with no other GPU work running so the timings are not contaminated.

The first backend is llama.cpp, which Typer already ships: a small C++ helper that links the library, keeps the model resident, and speaks a line-oriented protocol. Its prefix reuse is implemented in the server itself, which counts the common token prefix against the previous request, drops the diverged KV cells, and decodes only the suffix. We added one line of instrumentation to that path, emitting the reused and total token counts to stderr under an environment flag, so the reuse rate reported below is measured from the binary, not inferred.

The second backend is MLX, Apple's array framework, via mlx-lm. MLX does not value-match a prefix on its own, so to make the comparison fair the MLX harness performs the same bookkeeping by hand: it computes the common prefix, trims the prompt cache, and feeds only the suffix. Both lanes therefore run their prefix-reuse path on for the warm-on scenario and off for the cold-prefill scenario, measured at the same boundary.

The timing boundary is identical on both sides: the instant the request is fully written, to the first streamed token. We report p50 and p95 over twenty warm requests per cell (the first two discarded as warm-up) and six requests per cold cell. TTFT is the verdict metric. We also report decode throughput in tokens per second. One fairness caveat applies to end-to-end latency only: the two harnesses use slightly different stop rules and the MLX lane emits more tokens per suggestion on average, which inflates its end-to-end number but not its TTFT or its per-token decode rate, so we compare TTFT and per-token throughput and treat end-to-end as indicative.

Formally, for a request whose prompt shares a token prefix of length $c$ with the previous prompt of total length $L$, prefill cost scales with the suffix $L - c$ rather than $L$, and

$$\mathrm{TTFT} \approx t_{\text{fixed}} + (L - c)\, t_{\text{prefill}} + t_{\text{first-decode}},$$

where $t_{\text{fixed}}$ is per-call overhead. The whole game is making $c$ large (reuse) and $t_{\text{fixed}}$ small (in-process, no per-call graph build). The decode phase is bandwidth-bound: each token streams the model's weights once, so $t_{\text{decode}} \approx N_{\text{params}} \cdot b / \text{BW}$ for $b$ bytes per weight, which is why throughput falls roughly linearly with model size.

## 4. Prefix reuse is the dominant lever, and it already works

The reuse path was present in the shipping binary but had never been measured. The instrumentation confirms it fires: on the incremental stream the server reuses a median of two-thirds of the prompt tokens, and the effect on TTFT is large. Holding the backend and model fixed, turning reuse on cuts the llama.cpp warm first token from 23 to 14 ms at 0.6B, from 44 to 27 ms at 1.7B, and from 99 to 57 ms at 4B.

```chart
{"type":"bar","title":"llama.cpp warm TTFT p50 (ms): full prefill vs prefix reuse","unit":"ms","series":["full prefill (cache off)","prefix reuse (cache on)"],"data":[{"label":"Qwen3-0.6B q8","values":[23,14]},{"label":"Qwen3-1.7B q8","values":[44,27]},{"label":"Qwen3-4B q8","values":[99,57]}]}
```

The larger the model, the more reuse matters, because prefill is where size hurts most. At 4B the lever nearly halves TTFT. This is the single highest-leverage finding: the optimization that decides whether a given model size is viable was already implemented, and the work was to verify it rather than to build it.

## 5. Results: TTFT decides, and 1.7B clears the budget

The warm first token is the number that matters. On llama.cpp every model we tested through 4B serves it inside the 100 ms budget.

```chart
{"type":"bar","title":"llama.cpp warm-on TTFT p50 by model (ms). Budget = 100ms","unit":"ms","note":"every size through 4B clears the 100ms budget on the warm path; 1.7B (highlighted) is the recommended step up from the shipping 0.6B","data":[{"label":"Qwen3-0.6B q8","value":14},{"label":"Qwen3-1.7B q8","value":27,"highlight":true},{"label":"Gemma-4-E2B q4","value":47},{"label":"Qwen3-4B q8","value":57}]}
```

The backend comparison is decisive. At every size, llama.cpp's warm TTFT is far below MLX's, because MLX carries a fixed per-call cost (Python dispatch and graph evaluation) that sits at roughly 85 to 130 ms regardless of reuse, which is above llama.cpp's entire warm budget.

```chart
{"type":"bar","title":"Warm-on TTFT p50 (ms): llama.cpp vs MLX","unit":"ms","series":["llama.cpp","MLX"],"data":[{"label":"Qwen3-0.6B q8","values":[14,90]},{"label":"Qwen3-1.7B q8","values":[27,87]},{"label":"Qwen3-1.7B f16","values":[43,129]},{"label":"Qwen3-4B q8","values":[57,126]}]}
```

MLX is not slower in general. On raw decode throughput it leads at the larger sizes, consistent with its more efficient Metal matrix-vector kernels: at 1.7B it streams 87 tokens per second against llama.cpp's 75, and at 4B it leads 41 to 37. But decode throughput is the secondary metric, and MLX loses the primary one badly.

```chart
{"type":"bar","title":"Decode throughput p50 (tokens/sec): llama.cpp vs MLX","unit":"","series":["llama.cpp","MLX"],"data":[{"label":"Qwen3-0.6B q8","values":[144,126]},{"label":"Qwen3-1.7B q8","values":[75,87]},{"label":"Qwen3-4B q8","values":[37,41]}]}
```

The full grid, p50 unless noted:

| backend | model | quant | cold TTFT | warm-off TTFT | warm-on TTFT | decode tok/s | peak mem |
|---|---|---|---|---:|---:|---:|---:|
| llama.cpp | Qwen3-0.6B | q8 | 230 | 23 | **14** | 144 | n/a |
| llama.cpp | Qwen3-1.7B | q8 | 297 | 44 | **27** | 75 | n/a |
| llama.cpp | Qwen3-1.7B | f16 | 390 | 53 | 43 | 41 | n/a |
| llama.cpp | Qwen3-4B | q8 | 475 | 99 | **57** | 37 | n/a |
| llama.cpp | Gemma-4-E2B | q4 | 596 | 72 | **47** | 59 | n/a |
| MLX | Qwen3-0.6B | q8 | 96 | 96 | 90 | 126 | 1172 |
| MLX | Qwen3-1.7B | q8 | 121 | 117 | 87 | 87 | 1777 |
| MLX | Qwen3-1.7B | f16 | 130 | 134 | 129 | 52 | 3317 |
| MLX | Qwen3-4B | q8 | 202 | 200 | 126 | 41 | 4121 |

Two structural patterns are visible. On llama.cpp the cold cost (which includes model load) is large but paid once, and the warm path is an order of magnitude faster, so the steady state is what users live in. On MLX cold, warm-off, and warm-on are close together, because the per-call overhead dominates and reuse helps less; MLX never gets below its fixed floor.

## 6. Quantization: q8 is faster than fp16, not just smaller

We tested fp16 at 1.7B on both backends because intuition says full precision is the quality-preserving default and one tolerates a speed cost for it. The data says there is no speed cost to avoid: q8 is faster than fp16 as well as half the size. On llama.cpp, 1.7B warm TTFT is 27 ms at q8 against 43 ms at fp16, and decode rises from 41 to 75 tokens per second; the q8 file is 1.8 GB against 3.4 GB. The reason is mechanical. Decode is bandwidth-bound, and q8 moves half the bytes per token, so the smaller weights stream faster. fp16 buys nothing here. q8 is the operating point, which is convenient because it is also the precision at which quantization is effectively lossless for this task.

## 7. The newest models do not fit this path yet

The brief was to test the latest models. We checked. As of this writing the newest small models on the hub are Qwen3.5 (0.8B, 2B, 4B, released early 2026) and Gemma 4 (E2B, E4B, released April 2026). Both are multimodal, and the Qwen3.5 line uses a hybrid architecture combining gated linear-attention layers with a sparse mixture of experts. This matters for our purpose in two concrete ways. First, our inference stack does not support these architectures for the text path: the conversion of Qwen3.5-2B to our runtime is blocked by its multimodal hybrid design, not by effort. Second, and more fundamentally, the prefix-reuse lever that this entire report shows to be decisive depends on a standard attention KV cache; linear-attention layers do not have one in the same form, so the reuse semantics that give us a 27 ms warm token are not guaranteed to carry over. The latest deployable dense model for this workload is therefore the Qwen3 line at 0.6B to 4B, which is what we benchmarked. Gemma-4-E2B runs on llama.cpp (47 ms warm TTFT, competitive) but its MLX path is currently broken for the server use case, so we report it on llama.cpp only. Re-evaluating the hybrids is future work that depends on upstream runtime support, not something to block this decision on.

## 8. Limitations and threats to validity

**Sample size and single machine.** Twenty warm requests per cell on one M2 Pro. The p50/p95 spread is small and the cross-backend gaps are large relative to it, so the ranking is safe, but absolute numbers on an M1 or a thermally throttled machine will differ, and we have not yet run the shippable cells on a base M1.

**End-to-end is not directly comparable.** The two harnesses stop generation by slightly different rules and the MLX lane emits more tokens per suggestion, which inflates its end-to-end latency. We therefore rest the conclusion on TTFT and per-token throughput, which are measured identically, and treat end-to-end as indicative only.

**Quality is not yet measured for the larger models.** This report is about speed. We have established that 1.7B is fast enough; we have not yet confirmed how much its completion quality exceeds the shipping 0.6B on the typed benchmark, nor recalibrated the confidence gate for it. Speed clears the way; quality is the next report.

**Cold start is excluded from the budget.** The 100 ms budget is a warm-path claim. Cold TTFT is 297 ms at 1.7B on llama.cpp, paid once at process start or after a long idle. A separate residency-eviction effect (the GPU drops the model from its residency set after about three minutes idle) can reintroduce a cold-like spike on the next keystroke; the mitigation is identified (raise the Metal residency keep-alive) but not yet applied.

## 9. Decision and next steps

Ship a 1.7B at q8 on llama.cpp. It serves a warm first token in 27 ms, well inside the budget, at a 1.8 GB resident footprint, and it is a real capacity step up from the 0.6B that ships today. Do not migrate to MLX: it loses the metric that defines the product by a factor of three, and its decode-throughput advantage is on the secondary axis. Do not use fp16: q8 is faster and smaller.

The cheap llama.cpp wins identified alongside this benchmark and not yet applied are: raise the Metal residency keep-alive to remove the idle-eviction spike, confirm flash attention is enabled and right-size the context and micro-batch for a smaller resident footprint, and stop the two-model router from alternating models on consecutive keystrokes during its race, since each switch is a full reprefill that defeats reuse. The 4B result is a pleasant surprise: it clears the warm budget at 57 ms, which means the ceiling for ambient autocomplete is higher than assumed, though its lower decode rate and 4 GB footprint make 1.7B the better default on a 16 GB machine.

Separately, and out of scope here, the size results point at a second product mode we want to build later: typer-writer, an invoked (not ambient) local writing assistant using a 4B to 8B model for rewrite and drafting, where the latency budget is a second rather than 100 ms and the constraints in this report do not apply.

## 10. Reproducibility

The two harnesses, the shared results schema, and the suite runner are in [`bench/`](https://github.com/frgmt0/typer/tree/main/bench): `llamacpp_bench.py` drives the resident C++ helper and scrapes the measured reuse counter, `mlx_bench.py` reproduces prefix reuse by hand against mlx-lm, and `run_suite.sh` runs the full grid one cell at a time with nothing else on the GPU. The reuse instrumentation is the env-gated `REUSE` line in [`scripts/llama_server.cpp`](https://github.com/frgmt0/typer/blob/main/scripts/llama_server.cpp). Every number above is one JSON file under `bench/results/`. Everything runs on a single Apple Silicon laptop.
