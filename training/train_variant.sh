#!/usr/bin/env bash
# Train one human-grounded ablation variant end-to-end (sft -> fuse -> gguf), matched config.
# Each variant trains a fresh LoRA on its own mlx data dir into its own adapter/fused/gguf,
# under the memory cap, so the runs are comparable and none clobbers the live model.
#
#   ./train_variant.sh <name> <mlx_data_dir>
# e.g. ./train_variant.sh grounded data/mlx_grounded
set -euo pipefail
cd "$(dirname "$0")"

NAME="$1"; MLX="$2"
ADAPTER="adapters_${NAME}"
FUSED="fused_${NAME}"

# Matched ablation config: 24 LoRA layers, single 1100-iter chunk (no optimizer resets),
# 4-bit QLoRA base, Q8_0 output to match the typer-1-distill reference precision.
export BASE="Qwen/Qwen3-0.6B-Base"
export QLORA_BITS=4
export NUM_LAYERS=24
export ITERS=1100
export WINDOW=1100
export LR=2e-5
export QUANT=q8_0
export MLX_DATA="$MLX"
export ADAPTER FUSED
export LLAMA_CPP="$HOME/.cache/typer-build/llama.cpp"

echo "==> [$NAME] SFT on $MLX -> $ADAPTER (mem-capped)"
rm -f "$ADAPTER/.iters_done"
MEM_CAP_MB=1900 ./mem_guard.sh ./train.sh sft

echo "==> [$NAME] fuse -> $FUSED"
./train.sh fuse

echo "==> [$NAME] gguf ($QUANT)"
./train.sh gguf

echo "==> [$NAME] DONE -> $FUSED/typer-${QUANT}.gguf"
