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
#   ./train.sh general     central general-quality build: fp16 base, ALL layers, scaled
#                          corpus, more iters; clean held-out eval + offline gate calibration
#   ./train.sh eval-heldout       candidate vs Gemma on the never-trained held-out set
#   ./train.sh calibrate-offline  re-fit min_confidence from the model's held-out generations
#   ./train.sh retrain     incrementally personalize typer-1 on new accepts; promote the
#                          result over the live model only if it doesn't regress (rollback kept)
#   ./train.sh retrain-if-ready   the background guard (≥RETRAIN_EVERY new samples, on AC,
#                          idle, disk) — what the launchd agent runs; see install_retrain_agent.sh
#
# Override anything via env vars (see defaults below). This drives external tools
# (mlx-lm, mlx-lm-lora, llama.cpp); install them first (uv sync; clone llama.cpp).
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")"

# Capture user-supplied overrides BEFORE applying the generic defaults below. The
# subcommands (cold-start / general / retrain) set their own per-mode defaults via these
# *_USER values — otherwise the generic defaults here would already be set and would mask
# the subcommand's intent (e.g. BASE would always be Qwen, ITERS always 600).
for _v in BASE QUANT ITERS QLORA_BITS NUM_LAYERS WINDOW MAX_PER_SOURCE ADAPTER FUSED CORPUS GRAD_CKPT LR; do
  eval "${_v}_USER=\"\${${_v}:-}\""
done

BASE="${BASE:-Qwen/Qwen3-0.6B-Base}"        # or HuggingFaceTB/SmolLM2-360M
DATA="${DATA:-data}"
MLX_DATA="${MLX_DATA:-data/mlx}"
CORPUS="${CORPUS:-}"                          # optional dir of public-corpus .txt/.jsonl
MAX_PER_SOURCE="${MAX_PER_SOURCE:-8000}"      # cap per source in `corpus` (bounds downloads)
ADAPTER="${ADAPTER:-adapters}"
FUSED="${FUSED:-fused_model}"
QUANT="${QUANT:-Q5_K_M}"                      # Q5_K_M default; Q8_0 if calibration drifts
ITERS="${ITERS:-600}"
# Where convert_hf_to_gguf.py lives. Auto-detect a clone so the launchd agent works
# unattended; override LLAMA_CPP to force one.
if [ -z "${LLAMA_CPP:-}" ]; then
  for d in "$HOME/src/llama.cpp" "$HOME/.cache/typer-build/llama.cpp" "$HOME/llama.cpp"; do
    [ -f "$d/convert_hf_to_gguf.py" ] && { LLAMA_CPP="$d"; break; }
  done
  LLAMA_CPP="${LLAMA_CPP:-$HOME/src/llama.cpp}"
fi

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
LR="${LR:-1e-5}"                              # learning rate (mlx default). Each chunk restarts
                                             # the optimizer, so for long single-chunk runs set
                                             # WINDOW>=ITERS to avoid optimizer-reset slowdowns.
BASE_Q="${BASE_Q:-base-q${QLORA_BITS}}"       # local path for the quantized base
# The model the trainer actually loads: the quantized base when QLORA_BITS>0, else BASE.
GGUF_F16="${GGUF_F16:-$FUSED/model-f16.gguf}"
GGUF_OUT="${GGUF_OUT:-$FUSED/typer-${QUANT}.gguf}"
HELDOUT="${HELDOUT:-$DATA/sft.jsonl}"
RUN="uv run"

SERVER="${SERVER:-$HOME/.local/share/typer/typer-llama-server}"  # for the promote-gate eval
RETRAIN_ITERS="${RETRAIN_ITERS:-150}"   # extra iters per incremental retrain
RETRAIN_EVERY="${RETRAIN_EVERY:-100}"   # new captured samples that trigger a retrain
RETRAIN_IDLE="${RETRAIN_IDLE:-120}"     # require this many seconds of user idle
RETRAIN_MIN_FREE_GB="${RETRAIN_MIN_FREE_GB:-3}"
PROMOTE_SLACK="${PROMOTE_SLACK:-0.01}"  # candidate may trail live by this and still ship

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# First-word accuracy of a model on the frozen personal-accept set (0 if unavailable).
# The retrain promote-gate compares candidate vs live on this number.
eval_metric() {
  local m="$1"
  { [ -f "$m" ] && [ -s "$DATA/personal.jsonl" ] && [ -x "$SERVER" ]; } || { echo 0; return; }
  $RUN eval.py --server "$SERVER" --model "$m" --data "$DATA/personal.jsonl" --json --limit 200 2>/dev/null \
    | tail -1 \
    | $RUN python -c "import sys,json
try: print(json.load(sys.stdin)['first_word_acc'])
except Exception: print(0)" 2>/dev/null || echo 0
}

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
    say "Splitting sft.jsonl -> $MLX_DATA/{train,valid}.jsonl (90/10), text format"
    mkdir -p "$MLX_DATA"
    # Emit mlx-lm's "text" format: the prompt and its gold continuation joined into one
    # plain string — exactly the inference-time string (labeled context blocks + live
    # text, then the space-led continuation). This is the correct shape for a BASE /
    # continuation model: the prompt/completion format would route through a chat template
    # (which a base model has none of, and which we don't want — it injects turn markers).
    $RUN python - "$DATA/sft.jsonl" "$MLX_DATA" <<'PY'
import json, sys, random
src, out = sys.argv[1], sys.argv[2]
rows = []
for l in open(src, encoding="utf-8"):
    l = l.strip()
    if not l:
        continue
    o = json.loads(l)
    text = (o.get("prompt", "") + o.get("completion", "")).strip()
    if text:
        rows.append(json.dumps({"text": text}, ensure_ascii=False) + "\n")
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
      # LORA_CONFIG (optional YAML) supplies an lr_schedule (cosine decay + warmup) the CLI
      # can't express; CLI flags still override the rest.
      $RUN mlx_lm.lora --model "$TRAIN_MODEL" --train --data "$MLX_DATA" \
        --fine-tune-type lora --learning-rate "$LR" \
        --num-layers "$NUM_LAYERS" --batch-size "$BATCH" --grad-accumulation-steps "$GRAD_ACCUM" \
        --max-seq-length "$MAX_SEQ" $gc --iters "$chunk" --save-every "$SAVE_EVERY" \
        --adapter-path "$ADAPTER" $resume ${LORA_CONFIG:+-c "$LORA_CONFIG"}
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
    # Fuse into the SAME base the adapter was trained on. With QLoRA that's the 4-bit base,
    # whose layers are quantization-padded — fusing into the raw fp16 base mismatches those
    # shapes. --dequantize writes a standard fp16 model the GGUF converter can read.
    FUSE_MODEL="$BASE"; dq=""
    if [ "$QLORA_BITS" -gt 0 ] && [ -d "$BASE_Q" ]; then FUSE_MODEL="$BASE_Q"; dq="--dequantize"; fi
    say "Fusing adapter ($FUSE_MODEL${dq:+, dequantizing}) into $FUSED"
    rm -rf "$FUSED"
    $RUN mlx_lm.fuse --model "$FUSE_MODEL" --adapter-path "$ADAPTER" --save-path "$FUSED" $dq
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
    export BASE="${BASE_USER:-HuggingFaceTB/SmolLM2-360M}"
    export QUANT="${QUANT_USER:-q8_0}"
    export CORPUS="${CORPUS_USER:-corpus}"
    say "Cold-start: BASE=$BASE QUANT=$QUANT CORPUS=$CORPUS (resumable, <4GB; safe to Ctrl-C / sleep / re-run)"
    "$0" corpus; "$0" data; "$0" synth; "$0" preflight; "$0" prepare; "$0" quantize; "$0" sft; "$0" fuse; "$0" gguf
    say "Cold-start done. Next: ./train.sh eval  and  ./train.sh calibrate"
    ;;
  eval-heldout)
    # The honest general-quality scoreboard: candidate vs Gemma on docs NEVER trained on
    # (build_dataset reserves heldout.jsonl). This is the number to drive general dev.
    GEMMA="$HOME/Library/Application Support/typer/Models/gemma-4-E2B-i1-Q4_K_M.gguf"
    [ -s "$DATA/heldout.jsonl" ] || { echo "no $DATA/heldout.jsonl — run ./train.sh data first"; exit 1; }
    say "Held-out eval — candidate: $GGUF_OUT"
    $RUN eval.py --server "$SERVER" --model "$GGUF_OUT" --data "$DATA/heldout.jsonl" --limit 300
    [ -f "$GEMMA" ] && { say "Held-out eval — baseline: Gemma"; $RUN eval.py --server "$SERVER" --model "$GEMMA" --data "$DATA/heldout.jsonl" --limit 300; }
    ;;
  calibrate-offline)
    # Calibrate the confidence gate from the model's OWN generations on held-out prompts
    # (good = first word matched gold) — the doc-mandated offline calibration that works for
    # a fresh model with no real accepts yet. Re-fit min_confidence from the result.
    say "Offline gate calibration from held-out generations of $GGUF_OUT"
    $RUN eval.py --server "$SERVER" --model "$GGUF_OUT" --data "$DATA/heldout.jsonl" --limit 400 \
      --calib-out "$DATA/calib_offline.jsonl" >/dev/null
    $RUN calibrate_gate.py --data "$DATA/calib_offline.jsonl"
    ;;
  general)
    # Central, general-quality training — ships to everyone, uses public data only, and is
    # NOT memory-bound the way on-device personalization is. fp16 base, ALL layers, more
    # iters, the full scaled corpus; separate artifacts so it never touches the on-device
    # adapter. Cross-model distillation comes for free: Gemma's accepted suggestions are
    # already gold SFT targets (build_dataset tags every accept by the model that made it).
    export BASE="${BASE_USER:-HuggingFaceTB/SmolLM2-360M}"
    export QUANT="${QUANT_USER:-q8_0}"
    export CORPUS="${CORPUS_USER:-corpus}"
    export QLORA_BITS="${QLORA_BITS_USER:-0}"     # fp16 base (best quality; central isn't <1GB-bound)
    export NUM_LAYERS="${NUM_LAYERS_USER:--1}"    # all 32 layers
    export ITERS="${ITERS_USER:-3000}"
    # Single continuous chunk (WINDOW >= ITERS): central training must NOT reset the
    # optimizer mid-run the way the on-device chunking does — mlx's --save-every still
    # checkpoints for resume. Slightly higher LR than the 1e-5 on-device default to
    # actually move an all-layers run in a reasonable number of iters.
    export WINDOW="${WINDOW_USER:-$ITERS}"
    export LR="${LR_USER:-2e-5}"
    export MAX_PER_SOURCE="${MAX_PER_SOURCE_USER:-12000}"
    export ADAPTER="${ADAPTER_USER:-adapters_general}"
    export FUSED="${FUSED_USER:-fused_general}"
    say "General build: fp16 $BASE, all layers, $ITERS iters, corpus ≤$MAX_PER_SOURCE/source"
    "$0" corpus; "$0" data; "$0" prepare; "$0" sft; "$0" fuse; "$0" gguf
    "$0" eval-heldout
    "$0" calibrate-offline
    say "General model -> $FUSED/typer-${QUANT}.gguf. If it wins, install: cp it to"
    say "  ~/Library/Application Support/typer/Models/typer-1.gguf  (and rm -rf adapters/ to"
    say "  reseed on-device personalization from the new base), then restart Typer."
    ;;
  retrain)
    # Incremental on-device personalization. Continues the CURRENT typer-1 adapter on a
    # freshly rebuilt dataset (newly captured accepts + style + the general-corpus anchor
    # that resists forgetting), produces a candidate GGUF, and PROMOTES it over the live
    # typer-1 only if it doesn't regress on the frozen set of the user's real accepts.
    # Same <1GB resumable path as cold-start. Keeps a rollback copy.
    export BASE="${BASE_USER:-HuggingFaceTB/SmolLM2-360M}"; export QUANT="${QUANT_USER:-q8_0}"; export CORPUS="${CORPUS_USER:-corpus}"
    MODELS="$HOME/Library/Application Support/typer/Models"
    LIVE="$MODELS/typer-1.gguf"
    CAND="$FUSED/typer-candidate-${QUANT}.gguf"
    { [ -d "$ADAPTER" ] && [ -f "$ADAPTER/adapters.safetensors" ]; } || { echo "no current typer-1 adapter in $ADAPTER — run cold-start first"; exit 1; }
    "$0" data            # rebuild dataset including the newly captured accepts
    "$0" prepare
    rm -f "$ADAPTER/.iters_done"          # train RETRAIN_ITERS more, resuming the live adapter
    ITERS="$RETRAIN_ITERS" "$0" sft
    "$0" fuse
    GGUF_OUT="$CAND" "$0" gguf
    # Promote-gate: ship the candidate only if it holds up on the user's own accepts.
    if [ -f "$LIVE" ] && [ -s "$DATA/personal.jsonl" ] && [ -x "$SERVER" ]; then
      lm="$(eval_metric "$LIVE")"; cm="$(eval_metric "$CAND")"
      say "promote-gate (first-word acc on real accepts): live=$lm candidate=$cm (slack $PROMOTE_SLACK)"
      if awk "BEGIN{exit !(($cm + 0) >= ($lm + 0) - $PROMOTE_SLACK)}"; then
        cp "$LIVE" "$MODELS/typer-1.prev.gguf"
        cp "$CAND" "$LIVE"
        # Drop the live typer-1 helper so the router reloads the new weights on its next
        # pick (LlamaClient respawns a dead helper automatically) — no app restart.
        pkill -f "typer-llama-server --model-path.*typer-1.gguf" 2>/dev/null || true
        say "PROMOTED candidate -> typer-1.gguf (rollback at typer-1.prev.gguf)"
      else
        say "KEPT live model — candidate regressed. Candidate left at $CAND."
      fi
    else
      cp "$CAND" "$LIVE"
      say "No eval set/live model yet — installed candidate as typer-1.gguf."
    fi
    ;;
  retrain-if-ready)
    # The background guard the launchd agent calls. Only retrains when it won't bother the
    # user: enough new samples, on AC power, the user idle, and enough free disk.
    state="$DATA/.retrain_state"
    appdir="$HOME/Library/Application Support/typer"
    tlog="$appdir/training.jsonl"
    [ -f "$tlog" ] || { echo "no capture log yet — nothing to do"; exit 0; }
    now="$(wc -l < "$tlog" | tr -d ' ')"
    last="$(cat "$state" 2>/dev/null || echo 0)"
    new=$(( now - last ))
    [ "$new" -lt 0 ] && new="$now"        # log rolled (8MB cap) — treat all current as new
    [ "$new" -ge "$RETRAIN_EVERY" ] || { echo "only $new new samples (need $RETRAIN_EVERY)"; exit 0; }
    # Capture-then-test (not pipe-into-grep): awk/grep exiting early would SIGPIPE the
    # producer and, under `set -o pipefail`, abort the script silently.
    batt="$(pmset -g batt 2>/dev/null || true)"
    case "$batt" in *"AC Power"*) ;; *) echo "on battery — skip"; exit 0 ;; esac
    idle="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/{print int($NF/1000000000); exit}' || true)"
    [ "${idle:-0}" -ge "$RETRAIN_IDLE" ] || { echo "user active (idle ${idle:-0}s) — skip"; exit 0; }
    freeg="$(/bin/df -g "$appdir" | awk 'END{print $4}')"
    [ "${freeg:-0}" -ge "$RETRAIN_MIN_FREE_GB" ] || { echo "low disk (${freeg}G free) — skip"; exit 0; }
    say "ready: $new new samples, on AC, idle ${idle}s, ${freeg}G free — retraining typer-1"
    if "$0" retrain; then echo "$now" > "$state"; say "done; watermark=$now"; fi
    ;;
  *)
    grep -E '^#( |$)' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
