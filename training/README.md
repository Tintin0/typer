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
3. **Public corpora** — `fetch_corpus.py` pulls a bounded, categorized, permissively-licensed
   seed (OpenAssistant→chat, Dolly→docs, FineWeb-Edu→web, CodeParrot→code) into `corpus/`,
   streamed and capped so it stays small. Or point `--corpus` at your own dir of `.txt`/`.jsonl`.
   This is the "general users" base, learned **before** any per-user tailoring.

## Scripts

| Script | Deps | What it does |
|---|---|---|
| `fetch_corpus.py` | datasets | stream a bounded, categorized public-corpus seed → `corpus/*.jsonl`. Each source capped + isolated (a gated one is skipped, not fatal). |
| `build_dataset.py` | stdlib | capture + `style.txt` + `--corpus` → `sft/kto/dpo/calib.jsonl` in the app's prompt format. Drops zero-info short type-throughs, weights by information gain, re-screens secrets. Prints a **data-readiness report** (genuine positives per model vs the ≥300 KTO threshold). |
| `synth_negatives.py` | stdlib | cold-start preference data: corrupts SFT positives (echo, over-length, special-token, mid-word, generic, repeat, truncated) → `kto_synth/dpo_synth.jsonl`. No model/users needed. |
| `tokenizer_preflight.py` | transformers | hard word-boundary + BOS contract check for a candidate base. |
| `calibrate_gate.py` | stdlib | re-fit `min_confidence` from `calib.jsonl`; reports good/junk **separation (AUC)** — escalate the base if it collapses. |
| `eval.py` | stdlib | drive the real `typer-llama-server`; report first-word acc, matched-words, show-rate, latency/ttfp. The go/no-go meter vs Gemma. |
| `train.sh` | mlx-lm, llama.cpp | stage runner: `corpus ▸ data ▸ synth ▸ preflight ▸ prepare ▸ quantize ▸ sft ▸ fuse ▸ gguf ▸ eval ▸ calibrate`, plus `cold-start` (one command). |

## Cold start — one command

```bash
LLAMA_CPP=~/src/llama.cpp ./train.sh cold-start
```

Fetches the general corpus, builds the dataset, makes a 4-bit base, runs SFT, and writes a
`typer-q8_0.gguf`. Defaults to **SmolLM2-360M @ Q8_0** — the GGUF is produced directly by
`convert_hf_to_gguf.py --outtype q8_0`, so **no llama.cpp C++ build is needed** (only the
`convert_hf_to_gguf.py` script + the `gguf`/`torch` python deps). Override any of
`BASE` / `QUANT` / `CORPUS` / `ITERS` via env.

Then install + measure:

```bash
cp fused_model/typer-q8_0.gguf "~/Library/Application Support/typer/Models/typer-1.gguf"
scripts/build.sh                 # rebuild the app+server (the M1 BOS change is already in)
./train.sh eval && ./train.sh calibrate
```

The runtime A/B router then starts serving ~10% of suggestions from `typer-1.gguf` and
ratchets that share up as it earns real accepts (see the main README / `ModelRouter.swift`).

### Built to run in the background (low memory, interruptible)

The SFT stage is designed to **stay under ~4 GB RAM and survive interruption**, so it can
train while you work:

- **4-bit QLoRA base** (`quantize`): the frozen base is ~0.2 GB resident, not ~0.7 GB.
- **batch 1 × `GRAD_ACCUM`**, **`--max-seq-length 512`**, **`--grad-checkpoint`**, and LoRA
  on only the top **`NUM_LAYERS`** blocks — activation memory stays tiny.
- **Chunked + checkpointed**: training runs in `WINDOW`-iter chunks, saving the adapter and
  recording progress between them. Ctrl-C, sleep, or closing the lid costs at most ~`WINDOW`
  iters; just re-run `./train.sh sft` (or `cold-start`) and it resumes from the last chunk.
- Run it nicely in the background: `nice -n 10 ./train.sh cold-start > train.log 2>&1 &`.

Tune via env (`QLORA_BITS`, `BATCH`, `GRAD_ACCUM`, `MAX_SEQ`, `NUM_LAYERS`, `WINDOW`,
`ITERS`). Set `QLORA_BITS=0` for a full-precision base if you have the headroom.

## Later: real personalization (KTO)

Once real usage has produced **≥300–500 genuine (Tab/backtick) accepts attributed to a
model** (watch the readiness report / the menu's rollout line), run KTO on those —
on a rented GPU (`trl.experimental.kto`) or the same low-memory mlx path — A/B vs the
current model on a frozen accept set, and promote only on a win. See the design doc §5.

## Privacy

No user-derived file (`training.jsonl`, `style.txt`, `lexicon.json`) ever leaves the
device in this pipeline. Central training uses **public corpora only**. Personalization is
on-device LoRA. Generated artifacts under `data/`, `adapters/`, `fused_model/`, and any
`*.gguf` are git-ignored. See the design doc §6.
