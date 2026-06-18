# Typer autocomplete training

Pipeline to train Typer's own small autocomplete model — a **sub-1B, Apache-2.0** base,
fast on Apple Silicon, cheap to fine-tune — to replace the ~3.5 GB Gemma the app ships
today. The full design + rationale (base-model choice, the RL recipe, privacy
architecture, milestones) is in **[`../docs/autocomplete-model.md`](../docs/autocomplete-model.md)**.

Everything here runs with [`uv`](https://docs.astral.sh/uv/). The data/eval/calibration
scripts are **stdlib-only** (no install needed); training + GGUF conversion need the deps
in `pyproject.toml`.

```bash
cd training
uv sync                      # installs mlx-lm, transformers, … for the training stages
```

## The data contract

Typer's app continues plaintext: it feeds `<bos>` + labeled context blocks (with the
live line last) and the model writes the next 5–7 words. The model is a **base/continuation**
model, not a chat model, and the tokenizer must use **space-prefixed word-start tokens**
(`Ġword` / `▁word`) — the app's spacing, mid-word suppression, and `+0.5` lexicon boost
all depend on it. `tokenizer_preflight.py` enforces this before you adopt any base.

## Where the data comes from

1. **On-device capture** (opt-in). Enable *"Record my typing to train a local model"* in
   the Typer menu. The app writes `~/Library/Application Support/typer/training.jsonl` —
   one row per shown suggestion: the context, the suggestion, whether you accepted it,
   **how** (Tab / backtick / typed-through), the confidence, and below-gate suppressed
   suggestions for unbiased coverage. Secret-shaped text and credential apps are screened
   out at capture. It never leaves your Mac.
2. **Your own writing** — `style.txt` (already collected by the app) is sliced into
   prefix → short-continuation examples.
3. **Public corpora** — point `--corpus` at a dir of permissively-licensed `.txt`/`.jsonl`
   (FineWeb-Edu, OpenAssistant, Enron, …; see the design doc's license table).

## Scripts

| Script | Deps | What it does |
|---|---|---|
| `build_dataset.py` | stdlib | capture + `style.txt` + `--corpus` → `sft/kto/dpo/calib.jsonl` in the app's prompt format. Drops zero-info short type-throughs, weights by information gain, re-screens secrets. |
| `synth_negatives.py` | stdlib | cold-start preference data: corrupts SFT positives (echo, over-length, special-token, mid-word, generic, repeat, truncated) → `kto_synth/dpo_synth.jsonl`. No model/users needed. |
| `tokenizer_preflight.py` | transformers | hard word-boundary + BOS contract check for a candidate base. |
| `calibrate_gate.py` | stdlib | re-fit `min_confidence` from `calib.jsonl`; reports good/junk **separation (AUC)** — escalate the base if it collapses. |
| `eval.py` | stdlib | drive the real `typer-llama-server`; report first-word acc, matched-words, show-rate, latency/ttfp. The go/no-go meter vs Gemma. |
| `train.sh` | mlx-lm, llama.cpp | stage runner: `data ▸ synth ▸ preflight ▸ prepare ▸ sft ▸ dpo ▸ fuse ▸ gguf ▸ eval ▸ calibrate`. |

## Typical flow

```bash
# 1. Cold start (no users yet): public corpora + synthetic preferences
CORPUS=~/corpora ./train.sh data
./train.sh synth
BASE=Qwen/Qwen3-0.6B-Base ./train.sh preflight     # confirm the contract
./train.sh prepare && ./train.sh sft && ./train.sh dpo
./train.sh fuse && LLAMA_CPP=~/src/llama.cpp ./train.sh gguf

# 2. IMPORTANT: patch the server for the new model's BOS before loading the GGUF
#    (docs/autocomplete-model.md §3.3) — the literal "<bos>" is Gemma-only.

# 3. Measure vs Gemma, then re-fit the gate
./train.sh eval
./train.sh calibrate

# 4. Later, once real usage has produced ≥300–500 genuine (Tab/backtick) accepts:
#    run KTO on a rented GPU (trl.experimental.kto), A/B vs the base on a frozen
#    accept set, and promote only on a win. See the design doc §5.
```

## Privacy

No user-derived file (`training.jsonl`, `style.txt`, `lexicon.json`) ever leaves the
device in this pipeline. Central training uses **public corpora only**. Personalization is
on-device LoRA. Generated artifacts under `data/`, `adapters/`, `fused_model/`, and any
`*.gguf` are git-ignored. See the design doc §6.
