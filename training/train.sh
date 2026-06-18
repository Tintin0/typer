#!/usr/bin/env bash
# Orchestrate the Typer autocomplete training pipeline, one stage at a time.
#
#   ./train.sh data        build sft/kto/dpo/calib from local capture + --corpus
#   ./train.sh synth       generate cold-start synthetic preference negatives
#   ./train.sh preflight   verify the base model's tokenizer + BOS contract
#   ./train.sh prepare     split sft.jsonl into the train/valid dir mlx-lm wants
#   ./train.sh quantize    make a 4-bit QLoRA base (low-memory) — skipped if QLORA_BITS=0
#   ./train.sh sft         resumable low-memory LoRA SFT on Apple Silicon (mlx-lm)
#   ./train.sh dpo         synthetic-preference DPO on Apple Silicon (mlx-lm-lora)
#   ./train.sh fuse        fuse the LoRA into a standalone HF model
#   ./train.sh gguf        convert + quantize to GGUF for llama_server.cpp
#   ./train.sh eval        benchmark the GGUF vs held-out (and vs Gemma)
#   ./train.sh calibrate   re-fit min_confidence + report good/junk separation
#   ./train.sh corpus      fetch bounded general public-corpus seed (fetch_corpus.py)
#   ./train.sh all         data -> synth -> preflight -> prepare -> sft -> fuse -> gguf
#   ./train.sh cold-start  corpus -> all, defaulting to SmolLM2-360M @ Q8_0 (convert-only,
#                          no llama.cpp C++ build) — the one command to make typer-1.gguf
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
MAX_PER_SOURCE="${MAX_PER_SOURCE:-8000}"      # cap per source in `corpus` (bounds downloads)
ADAPTER="${ADAPTER:-adapters}"
FUSED="${FUSED:-fused_model}"
QUANT="${QUANT:-Q5_K_M}"                      # Q5_K_M default; Q8_0 if calibration drifts
ITERS="${ITERS:-600}"
LLAMA_CPP="${LLAMA_CPP:-$HOME/src/llama.cpp}" # full clone (convert_hf_to_gguf.py + quantize)

# --- Ultra-low-memory, interruptible SFT knobs --------------------------------
# Goal: a training run that stays under ~4 GB RAM and can be stopped/slept/restarted at any
# time without losing more than WINDOW iterations — so it runs in the background without
# impeding everyday use. How each knob buys that:
#   QLORA_BITS   4-bit quantized frozen base (mlx_lm.convert -q) — SmolLM2-360M ≈ 0.2 GB resident
#   BATCH=1 + GRAD_ACCUM  effective batch without the activation memory of a real batch
#   MAX_SEQ      our examples are short (≤600-char ctx + 7 words); 512 tokens is ample
#   NUM_LAYERS   LoRA only the top N transformer blocks → fewer trainable params + activations
#   GRAD_CKPT    recompute activations in backward instead of storing them
#   WINDOW       train in this many iters per process, checkpointing + recording progress
#                between chunks, so a kill/sleep/lid-close resumes from the last chunk
QLORA_BITS="${QLORA_BITS:-4}"                 # 0 disables quantization (full-precision base)
BATCH="${BATCH:-1}"
GRAD_ACCUM="${GRAD_ACCUM:-8}"                 # effective batch = BATCH * GRAD_ACCUM
MAX_SEQ="${MAX_SEQ:-512}"
NUM_LAYERS="${NUM_LAYERS:-8}"
GRAD_CKPT="${GRAD_CKPT:-1}"                   # 1 = pass --grad-checkpoint
WINDOW="${WINDOW:-150}"                       # iters per resumable chunk
SAVE_EVERY="${SAVE_EVERY:-50}"
BASE_Q="${BASE_Q:-base-q${QLORA_BITS}}"       # local path for the quantized base
# The model the trainer actually loads: the quantized base when QLORA_BITS>0, else BASE.
GGUF_F16="${GGUF_F16:-$FUSED/model-f16.gguf}"
GGUF_OUT="${GGUF_OUT:-$FUSED/typer-${QUANT}.gguf}"
HELDOUT="${HELDOUT:-$DATA/sft.jsonl}"
RUN="uv run"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

case "${1:-all}" in
  corpus)
    say "Fetching general public-corpus seed -> ${CORPUS:-corpus} (≤$MAX_PER_SOURCE/source)"
    $RUN fetch_corpus.py --out "${CORPUS:-corpus}" --max-per-source "$MAX_PER_SOURCE"
    ;;
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
  quantize)
    if [ "$QLORA_BITS" -le 0 ]; then say "QLORA_BITS=0 — training full-precision $BASE (skip)"; exit 0; fi
    if [ -d "$BASE_Q" ]; then say "Quantized base exists: $BASE_Q (skip)"; exit 0; fi
    say "Quantizing $BASE -> $BASE_Q (${QLORA_BITS}-bit) for low-memory QLoRA"
    $RUN mlx_lm.convert --hf-path "$BASE" --mlx-path "$BASE_Q" -q --q-bits "$QLORA_BITS"
    ;;
  sft)
    # Resumable, low-memory LoRA SFT. Trains in WINDOW-iter chunks: each chunk loads the
    # latest adapter (--resume-adapter-file) and checkpoints (--save-every), and a sentinel
    # records completed iters. A kill / sleep / lid-close therefore costs at most ~WINDOW
    # iters, and re-running `sft` continues where it left off. The QLoRA base + tiny batch +
    # gradient checkpointing + short sequences hold it under ~4 GB.
    mkdir -p "$ADAPTER"
    TRAIN_MODEL="$BASE"
    if [ "$QLORA_BITS" -gt 0 ] && [ -d "$BASE_Q" ]; then TRAIN_MODEL="$BASE_Q"; fi
    gc=""; [ "$GRAD_CKPT" = "1" ] && gc="--grad-checkpoint"
    done_file="$ADAPTER/.iters_done"
    done="$(cat "$done_file" 2>/dev/null || echo 0)"
    say "LoRA SFT on $TRAIN_MODEL — resumable ${WINDOW}-iter chunks (done=$done/$ITERS)"
    say "  mem: ${QLORA_BITS}-bit base, batch=$BATCH x accum=$GRAD_ACCUM, seq=$MAX_SEQ, layers=$NUM_LAYERS${gc:+, grad-ckpt}"
    while [ "$done" -lt "$ITERS" ]; do
      remain=$(( ITERS - done )); chunk=$(( remain < WINDOW ? remain : WINDOW ))
      resume=""; [ -f "$ADAPTER/adapters.safetensors" ] && resume="--resume-adapter-file $ADAPTER/adapters.safetensors"
      say "  +$chunk iters (from $done)"
      $RUN mlx_lm.lora --model "$TRAIN_MODEL" --train --data "$MLX_DATA" \
        --fine-tune-type lora --mask-prompt \
        --num-layers "$NUM_LAYERS" --batch-size "$BATCH" --grad-accumulation-steps "$GRAD_ACCUM" \
        --max-seq-length "$MAX_SEQ" $gc --iters "$chunk" --save-every "$SAVE_EVERY" \
        --adapter-path "$ADAPTER" $resume
      done=$(( done + chunk )); echo "$done" > "$done_file"
    done
    say "SFT done: $done iters -> $ADAPTER (rm $done_file to retrain from scratch)"
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
    say "Convert to GGUF ($QUANT) via $LLAMA_CPP"
    [ -f "$LLAMA_CPP/convert_hf_to_gguf.py" ] || { echo "Set LLAMA_CPP to a full llama.cpp clone (for convert_hf_to_gguf.py + the gguf python pkg)."; exit 1; }
    qlc="$(printf '%s' "$QUANT" | tr '[:upper:]' '[:lower:]')"
    case "$qlc" in
      f16|bf16|q8_0)
        # convert_hf_to_gguf.py emits these directly — no llama-quantize binary, so the
        # heavy llama.cpp C++ build stays out of the loop. Q8_0 of a 360M is ~0.4 GB and
        # docs/autocomplete-model.md lists it as a fully acceptable ship target.
        $RUN python "$LLAMA_CPP/convert_hf_to_gguf.py" "$FUSED" --outfile "$GGUF_OUT" --outtype "$qlc"
        ;;
      *)
        $RUN python "$LLAMA_CPP/convert_hf_to_gguf.py" "$FUSED" --outfile "$GGUF_F16" --outtype f16
        [ -x "$LLAMA_CPP/build/bin/llama-quantize" ] || { echo "$QUANT needs $LLAMA_CPP/build/bin/llama-quantize (build it, or use QUANT=q8_0 for the convert-only path)."; exit 1; }
        "$LLAMA_CPP/build/bin/llama-quantize" "$GGUF_F16" "$GGUF_OUT" "$QUANT"
        ;;
    esac
    echo "GGUF: $GGUF_OUT  — copy into ~/Library/Application Support/typer/Models/ as typer-1.gguf"
    echo "(rebuild the app with scripts/build.sh first, for the server BOS change — docs/autocomplete-model.md §3.3)"
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
    "$0" data; "$0" synth; "$0" preflight; "$0" prepare; "$0" quantize; "$0" sft; "$0" fuse; "$0" gguf
    say "Done. Next: ./train.sh eval  and  ./train.sh calibrate"
    ;;
  cold-start)
    # One command to build the typer-1 candidate from general public examples. Defaults
    # to SmolLM2-360M @ Q8_0 (convert-only — no llama.cpp C++ build, light on a 16 GB Mac).
    # Override BASE/QUANT/CORPUS/ITERS via env. DPO is skipped here (optional extra;
    # SFT + offline gate calibration give a shippable cold-start on their own).
    export BASE="${BASE:-HuggingFaceTB/SmolLM2-360M}"
    export QUANT="${QUANT:-q8_0}"
    export CORPUS="${CORPUS:-corpus}"
    say "Cold-start: BASE=$BASE QUANT=$QUANT CORPUS=$CORPUS (resumable, <4GB; safe to Ctrl-C / sleep / re-run)"
    "$0" corpus; "$0" data; "$0" synth; "$0" preflight; "$0" prepare; "$0" quantize; "$0" sft; "$0" fuse; "$0" gguf
    say "Cold-start done. Next: ./train.sh eval  and  ./train.sh calibrate"
    ;;
  *)
    grep -E '^#( |$)' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
