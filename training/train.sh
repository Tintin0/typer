#!/usr/bin/env bash
# Orchestrate the Typer autocomplete training pipeline, one stage at a time.
#
#   ./train.sh data        build sft/kto/dpo/calib from local capture + --corpus
#   ./train.sh synth       generate cold-start synthetic preference negatives
#   ./train.sh preflight   verify the base model's tokenizer + BOS contract
#   ./train.sh prepare     split sft.jsonl into the train/valid dir mlx-lm wants
#   ./train.sh sft         LoRA SFT on Apple Silicon (mlx-lm)
#   ./train.sh dpo         synthetic-preference DPO on Apple Silicon (mlx-lm-lora)
#   ./train.sh fuse        fuse the LoRA into a standalone HF model
#   ./train.sh gguf        convert + quantize to GGUF for llama_server.cpp
#   ./train.sh eval        benchmark the GGUF vs held-out (and vs Gemma)
#   ./train.sh calibrate   re-fit min_confidence + report good/junk separation
#   ./train.sh all         data -> synth -> preflight -> prepare -> sft -> fuse -> gguf
#
# Override anything via env vars (see defaults below). This drives external tools
# (mlx-lm, mlx-lm-lora, llama.cpp); install them first (uv sync; clone llama.cpp).
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")"

BASE="${BASE:-Qwen/Qwen3-0.6B-Base}"        # or HuggingFaceTB/SmolLM2-360M
DATA="${DATA:-data}"
MLX_DATA="${MLX_DATA:-data/mlx}"
CORPUS="${CORPUS:-}"                          # optional dir of public-corpus .txt/.jsonl
ADAPTER="${ADAPTER:-adapters}"
FUSED="${FUSED:-fused_model}"
QUANT="${QUANT:-Q5_K_M}"                      # Q5_K_M default; Q8_0 if calibration drifts
ITERS="${ITERS:-600}"
BATCH="${BATCH:-4}"
LLAMA_CPP="${LLAMA_CPP:-$HOME/src/llama.cpp}" # full clone (convert_hf_to_gguf.py + quantize)
GGUF_F16="${GGUF_F16:-$FUSED/model-f16.gguf}"
GGUF_OUT="${GGUF_OUT:-$FUSED/typer-${QUANT}.gguf}"
HELDOUT="${HELDOUT:-$DATA/sft.jsonl}"
RUN="uv run"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

case "${1:-all}" in
  data)
    say "Building datasets from local capture${CORPUS:+ + corpus $CORPUS}"
    $RUN build_dataset.py ${CORPUS:+--corpus "$CORPUS"} --out "$DATA"
    ;;
  synth)
    say "Generating synthetic cold-start preference negatives"
    $RUN synth_negatives.py --sft "$DATA/sft.jsonl" --out "$DATA"
    ;;
  preflight)
    say "Tokenizer + BOS pre-flight for $BASE"
    $RUN tokenizer_preflight.py --model "$BASE"
    ;;
  prepare)
    say "Splitting sft.jsonl -> $MLX_DATA/{train,valid}.jsonl (90/10)"
    mkdir -p "$MLX_DATA"
    $RUN python - "$DATA/sft.jsonl" "$MLX_DATA" <<'PY'
import json, sys, random
src, out = sys.argv[1], sys.argv[2]
rows = [l for l in open(src, encoding="utf-8") if l.strip()]
random.Random(0).shuffle(rows)
k = max(1, len(rows) // 10)
open(f"{out}/valid.jsonl", "w").writelines(rows[:k])
open(f"{out}/train.jsonl", "w").writelines(rows[k:])
print(f"train {len(rows)-k}  valid {k}")
PY
    ;;
  sft)
    say "LoRA SFT (mlx-lm) on $BASE"
    $RUN mlx_lm.lora --model "$BASE" --train --data "$MLX_DATA" \
      --fine-tune-type lora --mask-prompt --iters "$ITERS" --batch-size "$BATCH" \
      --adapter-path "$ADAPTER"
    ;;
  dpo)
    say "Synthetic-preference DPO (mlx-lm-lora) — verify flags against your version"
    $RUN mlx_lm_lora.train --model "$BASE" --train-mode dpo --beta 0.1 \
      --data "$DATA/dpo_synth.jsonl" --adapter-path "$ADAPTER"
    ;;
  fuse)
    say "Fusing adapter into $FUSED"
    $RUN mlx_lm.fuse --model "$BASE" --adapter-path "$ADAPTER" --save-path "$FUSED"
    ;;
  gguf)
    say "Convert + quantize to GGUF ($QUANT) via $LLAMA_CPP"
    [ -f "$LLAMA_CPP/convert_hf_to_gguf.py" ] || { echo "Set LLAMA_CPP to a full llama.cpp clone."; exit 1; }
    $RUN python "$LLAMA_CPP/convert_hf_to_gguf.py" "$FUSED" --outfile "$GGUF_F16" --outtype f16
    "$LLAMA_CPP/build/bin/llama-quantize" "$GGUF_F16" "$GGUF_OUT" "$QUANT"
    echo "GGUF: $GGUF_OUT  — drop into ~/Library/Application Support/typer/Models/ (after the server BOS change, see docs/autocomplete-model.md §3.3)"
    ;;
  eval)
    say "Eval $GGUF_OUT vs held-out"
    $RUN eval.py --model "$GGUF_OUT" --data "$HELDOUT"
    ;;
  calibrate)
    say "Recalibrating the confidence gate"
    $RUN calibrate_gate.py --data "$DATA/calib.jsonl"
    ;;
  all)
    "$0" data; "$0" synth; "$0" preflight; "$0" prepare; "$0" sft; "$0" fuse; "$0" gguf
    say "Done. Next: ./train.sh eval  and  ./train.sh calibrate"
    ;;
  *)
    grep -E '^#( |$)' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
