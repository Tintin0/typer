# Typer Inference Benchmark Harness

This directory benchmarks the two candidate inference backends for Typer's always-on
autocomplete helper against the **TTFT-first** product constraint described in
`docs/perf-research.md`. TTFT (time to first ghost-text token) is the verdict metric; decode
TPS is secondary; memory and battery are constraints.

- `llamacpp_bench.py` - drives the C++ JSONL helper (`scripts/llama_server.cpp`, binary at
  `~/.local/share/typer/typer-llama-server`).
- `mlx_bench.py` - drives mlx-lm 0.31.x in-process (`training/.venv`).

Both write results in the **shared JSON schema** below so a single comparison reads from one
shape. Run everything with `uv` per the project workflow; never call bare `python`/`pip`.

> Status: the two `*_bench.py` scripts are specified here but are written separately. This
> README is the contract they implement. Before any run is meaningful, the C++ `--check`
> flag must be extended to emit the JSON timing fields (see "Harness prerequisite").

---

## Harness prerequisite (do this first)

`scripts/llama_server.cpp`'s `--check` currently emits only `latency_ms` to stderr
(line ~587). The benchmark needs structured per-request timing from **both** backends in one
schema. Extend the C++ server's per-request response (and `--check`) to emit, as one JSON
line:

```json
{"ttft_ms": 0.0, "prefill_tok": 0, "decode_tok": 0, "tokens_skipped": 0, "total_ms": 0.0}
```

`ttft_ms` is measured at **bytes-on-stdout** for the first ghost token. `tokens_skipped` is
`common` from `prepare_prompt` (the prefix-reuse hit size). The MLX harness measures
`ttft_ms` at the **first token yielded by `stream_generate`** and reports `tokens_skipped`
from the prompt-cache prefix match. These two boundaries are defined to be equivalent for
fairness (see Fairness rules).

---

## How to run

```bash
# Activate the training venv (mlx-lm lives here)
source training/.venv/bin/activate

# Build the C++ helper if needed
bash scripts/build.sh        # binary -> ~/.local/share/typer/typer-llama-server

# llama.cpp lane: one model/quant/scenario cell
uv run bench/llamacpp_bench.py \
  --server ~/.local/share/typer/typer-llama-server \
  --model "$HOME/Library/Application Support/typer/Models/Qwen3-1.7B-q8_0.gguf" \
  --data training/data/typed_eval.jsonl \
  --scenario warm_reuse_on \
  --n-ctx 1024 --max-words 7 --runs 50 \
  --label "llamacpp/qwen3-1.7b/q8_0" \
  --out bench/results/llamacpp_qwen3-1.7b_q8_0_warm.json

# MLX lane: the comparable cell
uv run bench/mlx_bench.py \
  --model ~/Library/Application\ Support/typer/Models/Qwen3-1.7B-8bit \
  --data training/data/typed_eval.jsonl \
  --scenario warm_reuse_on \
  --n-ctx 1024 --max-words 7 --runs 50 \
  --label "mlx/qwen3-1.7b/q8" \
  --out bench/results/mlx_qwen3-1.7b_q8_warm.json
```

Both scripts accept the same core flags: `--model`, `--data`, `--scenario`, `--n-ctx`,
`--max-words`, `--runs`, `--label`, `--out`. `llamacpp_bench.py` additionally takes
`--server`; `mlx_bench.py` additionally takes `--draft-model` and `--num-draft-tokens` for
the (deferred) speculative cells and `--kv-bits` for the KV-quant sub-axis.

The eval dataset `training/data/typed_eval.jsonl` has 180 rows with fields
`context`, `app`, `register`, `completion`, `source`. The benchmark uses `context` (the
prompt) and `app`/`register` only for grouping; `completion` is for the *quality* pass, not
the speed pass.

---

## Shared results JSON schema

One file per cell. Every numeric latency is milliseconds.

```json
{
  "schema_version": 1,
  "backend": "llamacpp | mlx",
  "label": "llamacpp/qwen3-1.7b/q8_0",
  "model": {
    "path": "/abs/path/to/model",
    "arch": "qwen3",
    "weight_quant": "q8_0",
    "file_size_mb": 1830,
    "kv_quant": "f16 | q8_0 | kv_bits=8"
  },
  "host": {
    "machine": "Apple M2 Pro",
    "ram_gb": 16,
    "macos": "26.4 (25E246)",
    "ac_power": true,
    "die_temp_c_start": 0.0,
    "llamacpp_commit": "32e806b",
    "mlx_lm_version": "0.31.3"
  },
  "config": {
    "n_ctx": 1024,
    "n_ubatch": 128,
    "n_threads": 2,
    "flash_attn": "enabled",
    "max_words": 7,
    "residency_keep_alive_s": 3600
  },
  "scenario": "cold | warm_reuse_off | warm_reuse_on | idle_resume",
  "runs": 50,
  "warmup_discarded": 2,
  "metrics": {
    "ttft_ms_p50": 0.0,
    "ttft_ms_p95": 0.0,
    "decode_tps": 0.0,
    "e2e_ms_p50": 0.0,
    "e2e_ms_p95": 0.0,
    "effective_prefill_tok_mean": 0.0,
    "tokens_skipped_mean": 0.0,
    "prefix_reuse_hit_rate": 0.0,
    "peak_rss_mb": 0.0,
    "unified_mem_mb": 0.0,
    "cpu_gpu_ms_per_suggestion": 0.0
  },
  "raw_runs": [
    {"ttft_ms": 0.0, "decode_tps": 0.0, "e2e_ms": 0.0,
     "prefill_tok": 0, "decode_tok": 0, "tokens_skipped": 0}
  ]
}
```

Notes:
- **Never blend cold and warm TTFT.** They are separate scenarios and separate files.
- `prefix_reuse_hit_rate` = fraction of runs where `tokens_skipped > 0` and
  `tokens_skipped / prompt_tok > 0.8`. This is how you confirm lever 1 is firing.
- `cpu_gpu_ms_per_suggestion` is the battery proxy from
  `powermetrics --samplers cpu_power,gpu_power` over a fixed replay.

---

## Model / quant / scenario matrix

### Models

| Model | Role | Local file (if present) |
|-------|------|-------------------------|
| Qwen3-1.7B | **PRIMARY** | confirm `typer-1l.gguf` (1.2 GB) arch/quant via gguf metadata first |
| Qwen3-4B | ceiling | download |
| Gemma-3n-E2B | experimental | `gemma-4-E2B-i1-Q4_K_M.gguf` (3.5 GB); MLX server path BROKEN (#1384/#1396) - MLX = generate-only, may not get reuse on SWA layers |
| Qwen3-0.6B | regression floor (what ships today) | `typer-1-raw.gguf` / `typer-1-distill.gguf` (639 MB) |

Always judge larger models against the 0.6B floor so every step-up is measured against what
ships today.

### Quants

| Quant | Purpose |
|-------|---------|
| fp16 | quality/losslessness anchor (reference) |
| q8_0 / MLX q8 | the lossless-ish default the project prefers |
| q4_K_M / MLX q4 affine g64 | battery/memory floor; ship only if quality holds |

Cross-cutting **KV-cache dtype** is a sub-axis applied to the **winning weight quant only**:
F16 KV vs Q8_0 KV (llama.cpp, requires FA ENABLED) / `kv_bits=8` (MLX). Do NOT sweep KV
dtype across every cell - pin weights first, then test KV on the leader.

### Scenarios

| Scenario | What it isolates |
|----------|------------------|
| `cold` | spawn helper, first request: model load + Metal graph build + first prefill. MLX adds ~0.5-2 s graph compile - warm with a dummy call and report both. |
| `warm_reuse_off` | warm process, fresh cache each call: honest worst-case full prefill (after app switch / big edit). |
| `warm_reuse_on` | warm process, **synthesized incremental replay**: replay each `context` as a growing prefix (+1-5 tokens/step) so reuse is exercised the way Typer hits it. The raw jsonl is independent prompts; you MUST derive the incremental stream or warm numbers are meaningless. |
| `idle_resume` | warm, sleep >3 min (Metal residency keep-alive default 180 s), then one request: measures the residency-eviction spike that `GGML_METAL_RESIDENCY_KEEP_ALIVE_S=3600` targets. |

### Per-machine

Run the full grid on **M2 Pro 16 GB (primary)**. For shippable cells only, also run an
**M1 / 8 GB base** box - Qwen3-4B and Gemma-3n may not fit alongside the OS there.

---

## Fairness rules (comparing the two backends)

1. **Same physical box, same macOS build, AC power, fixed thermal state.** Insert a cooldown
   between runs; log `die_temp_c_start`. Disable Spotlight indexing and Time Machine during
   runs.
2. **Identical prompts and `max_words`.** The C++ server clamps `max_words` to `[1,32]` and
   the harness adds slack; mirror the exact effective `max_tokens` in the MLX harness.
3. **Pin `n_ctx` identically** (e.g. 1024) on both backends.
4. **Measure TTFT at the same logical boundary:** bytes-on-stdout for the C++ JSONL server
   vs first token yielded by `stream_generate` for in-process MLX. Prefer **in-process MLX**
   (not `mlx_lm.server`) so there is no HTTP/IPC layer to subtract - this matches the C++
   in-process measurement.
5. **Both run their prefix-reuse path ON for the warm scenario** (llama.cpp `prepare_prompt`
   vs MLX `make_prompt_cache` + `trim_prompt_cache`) and **OFF for the cold/`warm_reuse_off`
   scenario**, measured identically.
6. **N >= 50 warm requests; discard the first 2 (warmup); report p50/p95, never mean.**
7. **Comparable, not equal quant:** llama.cpp q4_K_M and MLX q4 affine g64 are close but NOT
   identical bit layouts. Report both file sizes and treat as "comparable".

---

## Quality check (run AFTER speed, never during)

Use the existing `training/eval_compare.py` harness over all 180 `typed_eval.jsonl` prompts
(gold field: `completion`). Order:

1. Greedy/deterministic (temp 0) at fp16 to establish each model's gold baseline.
2. Re-run each quant and KV-quant cell; compute exact-token-match and prefix-overlap vs the
   fp16 output of the **same** model (self-consistency), plus task accuracy vs the dataset
   `completion` field.
3. Gates:
   - **q8_0** must match fp16 within **<= 1% exact-match delta** to ship.
   - **q4** must hold an agreed quality floor or it is rejected regardless of speed.
   - **Q8_0 KV** must show **no** regression vs F16 KV on the same weights before it ships.
   - **Confidence-signal sanity:** `last_avg_prob` distribution unchanged so the UI's
     low-confidence suppression stays calibrated.

```bash
uv run training/eval_compare.py \
  --harness "$HOME/Library/Application Support/typer/Models/Qwen3-1.7B-q8_0.gguf" \
  --raw     "$HOME/Library/Application Support/typer/Models/Qwen3-1.7B-fp16.gguf"
```

---

## Results table (fill in after the real runs)

All values measured on M2 Pro 16 GB, macOS 26.4, AC power, `n_ctx=1024`, `max_words=7`,
N=50, p50/p95, warmup discarded. **TTFT warm = the verdict metric.** Numbers below are
PLACEHOLDERS - every cell is currently UNVERIFIED.

### Primary: Qwen3-1.7B, q8_0 weights, F16 KV

| Backend | Scenario | TTFT p50 | TTFT p95 | Decode TPS | E2E p50 | Reuse hit % | Peak mem MB |
|---------|----------|----------|----------|-----------|---------|-------------|-------------|
| llamacpp | cold | _ | _ | _ | _ | n/a | _ |
| llamacpp | warm_reuse_off | _ | _ | _ | _ | 0 | _ |
| llamacpp | warm_reuse_on | _ | _ | _ | _ | _ | _ |
| llamacpp | idle_resume | _ | _ | _ | _ | _ | _ |
| mlx | cold | _ | _ | _ | _ | n/a | _ |
| mlx | warm_reuse_off | _ | _ | _ | _ | 0 | _ |
| mlx | warm_reuse_on | _ | _ | _ | _ | _ | _ |

### Regression floor: Qwen3-0.6B (what ships today)

| Backend | Scenario | TTFT p50 | TTFT p95 | Decode TPS | E2E p50 |
|---------|----------|----------|----------|-----------|---------|
| llamacpp | cold | ~135 (from `--check`) | _ | _ | _ |
| llamacpp | warm_reuse_on | _ | _ | _ | _ |

### KV-quant sub-axis (winning weight quant only)

| Backend | KV dtype | TTFT warm p50 | Decode TPS | Mem MB | Quality gate |
|---------|----------|---------------|-----------|--------|--------------|
| llamacpp | F16 | _ | _ | _ | baseline |
| llamacpp | Q8_0 | _ | _ | _ | pass/fail vs F16 |
| mlx | f16 | _ | _ | _ | baseline |
| mlx | kv_bits=8 | _ | _ | _ | pass/fail vs f16 |

### Ceiling: Qwen3-4B (TPS-focused; M2 Pro only)

| Backend | Quant | TTFT warm p50 | Decode TPS | Mem MB |
|---------|-------|---------------|-----------|--------|
| llamacpp | q4_K_M | _ | _ | _ |
| mlx | q4 g64 | _ | _ | _ |

### Experimental: Gemma-3n-E2B (llama.cpp only; MLX server broken)

| Backend | Quant | TTFT warm p50 | Reuse hit % (verify SWA reuse fires) | Mem MB |
|---------|-------|---------------|--------------------------------------|--------|
| llamacpp | Q4_K_M | _ | _ (check `common>0` with swa_full=false) | _ |

---

The verdict: pick the backend + model + quant whose **`warm_reuse_on` TTFT p50/p95** stays
inside the ~100 ms budget while passing the quality gates. Per `docs/perf-research.md` the
expected winner is llama.cpp + Qwen3-1.7B q8_0, but that expectation is not load-bearing
until these cells are filled with real measurements.
