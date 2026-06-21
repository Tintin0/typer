#!/usr/bin/env bash
# Run the full TTFT/TPS suite across backends x models x scenarios, one cell at a time.
# CRITICAL: nothing else GPU-heavy may run concurrently — that would contaminate latency.
# llama.cpp lane drives the C++ helper (uv run, stdlib only); MLX lane needs training/.venv.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PY_MLX="$REPO/training/.venv/bin/python"
M="$HOME/Library/Application Support/typer/Models"
BM="$REPO/training/bench_models"
export TYPER_REUSE_LOG=1
mkdir -p bench/results

WARM_N=20
COLD_N=6
SCEN=(cold warm-off warm-on)

# label|gguf_path  (llama.cpp lane)
LLAMA=(
  "qwen3-0.6b-q8|$M/typer-1-distill.gguf"
  "qwen3-1.7b-q8|$BM/qwen3-1.7b-q8_0.gguf"
  "qwen3-1.7b-f16|$BM/qwen3-1.7b-f16.gguf"
  "qwen3-4b-q8|$BM/qwen3-4b-q8_0.gguf"
  "gemma-4-e2b-q4|$M/gemma-4-E2B-i1-Q4_K_M.gguf"
)
# label|mlx_dir_or_hf|quantlabel  (MLX lane)
MLX=(
  "qwen3-0.6b-q8|Qwen/Qwen3-0.6B-Base|q8"
  "qwen3-1.7b-q8|$BM/qwen3-1.7b-mlx-q8|q8"
  "qwen3-1.7b-f16|$BM/qwen3-1.7b-mlx-f16|fp16"
  "qwen3-4b-q8|$BM/qwen3-4b-mlx-q8|q8"
)

n_for() { [ "$1" = cold ] && echo "$COLD_N" || echo "$WARM_N"; }

echo "===== LLAMA.CPP LANE ====="
for spec in "${LLAMA[@]}"; do
  label="${spec%%|*}"; gguf="${spec#*|}"
  if [ ! -f "$gguf" ]; then echo "SKIP $label (missing $gguf)"; continue; fi
  for s in "${SCEN[@]}"; do
    out="bench/results/llamacpp_${label}_${s}.json"
    echo ">> llama.cpp $label $s (n=$(n_for "$s"))"
    uv run bench/llamacpp_bench.py --model "$gguf" --scenario "$s" --n "$(n_for "$s")" --out "$out" >/dev/null 2>>/tmp/suite_err.log \
      && echo "   ok -> $out" || echo "   FAIL $label $s (see /tmp/suite_err.log)"
  done
done

echo "===== MLX LANE ====="
for spec in "${MLX[@]}"; do
  label="${spec%%|*}"; rest="${spec#*|}"; mdir="${rest%%|*}"; q="${rest#*|}"
  for s in "${SCEN[@]}"; do
    out="bench/results/mlx_${label}_${s}.json"
    echo ">> mlx $label $s (n=$(n_for "$s"))"
    "$PY_MLX" bench/mlx_bench.py --model "$mdir" --quant "$q" --scenario "$s" --n "$(n_for "$s")" --out "$out" >/dev/null 2>>/tmp/suite_err.log \
      && echo "   ok -> $out" || echo "   FAIL $label $s (see /tmp/suite_err.log)"
  done
done
echo "===== SUITE DONE ====="