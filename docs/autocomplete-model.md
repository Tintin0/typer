# Typer Autocomplete Model — Build Plan

Status: **locked.** Scope: replace the on-device completion model behind
`scripts/llama_server.cpp` (currently `gemma-4-E2B-i1-Q4_K_M.gguf`, 3.5 GB on disk,
~400 MB+ resident, custom Gemma license) with a **sub-1B, Apache-2.0 base** that is fast
on Apple Silicon and cheap to train — plus the data pipeline and a de-confounded RL
recipe.

This plan was produced by a research + adversarial-review pass (6 web-grounded research
threads → 3 critics: feasibility, RL-soundness, privacy/generalization → synthesis). It
**follows the critiques over the raw research** wherever they conflict; the biggest
reversals are marked **[OVERRIDE]**. Every code reference was checked against the tree.

---

## Implementation status (what's already in the repo)

The data foundation and the offline pipeline are built and tested; the model swap and
real RL are the remaining work.

| Piece | State | Where |
|---|---|---|
| On-device capture (opt-in JSONL, schema v2) | **DONE** | `scripts/typer/TrainingLog.swift`, `TyperApp+Completion.swift` |
| `accept_kind` (tab/backtick/typethrough) de-confounding | **DONE** | `resolveCompletionOutcome(_:via:)` + 5 call sites |
| Capture-time secret screen + credential-app denylist | **DONE** | `TrainingLog.looksSensitive`, `sensitiveAppBundles` |
| Below-gate **exploration logging** (suppressed-region negatives) | **DONE** | `noteSuppressed(...)` at both gate points |
| Version tags (`min_conf`, `max_words`, `model`) | **DONE** | `TrainingLog.Record` |
| One-time consent sheet + "Inspect training data…" | **DONE** | `TyperApp+Menu.swift` |
| Dataset builder → SFT / KTO / DPO / calib | **DONE** | `training/build_dataset.py` |
| Synthetic cold-start negatives (Phase 0.5) | **DONE** | `training/synth_negatives.py` |
| Confidence-gate recalibration + separation AUC | **DONE** | `training/calibrate_gate.py` |
| Tokenizer word-boundary + BOS pre-flight | **DONE** | `training/tokenizer_preflight.py` |
| Go/no-go eval over the real server protocol | **DONE** | `training/eval.py` |
| **Server BOS + special-bias change** (per new model) | **TODO (M1)** | `scripts/llama_server.cpp` |
| **Reset-also-deletes-LoRA** | **TODO (M6)** | once a LoRA exists |
| **ε-exploration *showing* path** (occasionally show below-gate) | **TODO (M7)** | optional, opt-in |
| Train + ship a base; collect real positives; KTO | **TODO (M2–M8)** | this plan |

---

## 0. Executive summary + locked stack

Replace Gemma with **Qwen3-0.6B-Base** (default) or **SmolLM2-360M-Base** (lighter
fallback), both Apache-2.0, both honoring the leading-space word-boundary contract the
server hard-depends on. This is **not a drop-in**: `prompt_complete()` hardcodes a
literal `"<bos>"` that is correct only for Gemma and tokenizes to junk in Qwen/SmolLM
vocabularies, and `init_biases()` bans special tokens by Gemma-specific literal strings —
both need a C++ change + rebuild. Bring the model up in three phases — **cold-start SFT**
(public corpora + the user's `style.txt`) → **synthetic-preference DPO/KTO** (programmatic
corruptions, which also calibrate the confidence gate offline so a logging-OFF install
ships calibrated) → **real KTO** on logged accept/reject, gated behind a de-confounded
reward. Personalization is **on-device LoRA only, zero upload by default**; DP/SecAgg/
federation are dropped from the default path (incoherent for a single user) and reserved
for an opt-in mode not built in v1.

### Decision table

| Decision | Choice | Why (and what we overrode) |
|---|---|---|
| Default base | **Qwen3-0.6B-Base** (Apache-2.0) | Best sub-1B calibration/quality; byte-level-BPE space-prefix contract holds. **[OVERRIDE]** of the 360M lean: 360M's ability to reproduce Gemma's ~0.07 good/junk confidence separation is *unproven*; default up, drop to 360M only if eval proves it holds. |
| Fallback base | **SmolLM2-360M-Base** (Apache-2.0, vocab 49,152) | Smallest viable, fastest first token, tiny softmax. Use if cold-prompt prefill at 0.6B blows the latency budget. |
| Disqualified | Gemma-3-270M (viral license), Llama-3.2-1B (community license + size ceiling), keyboard LSTMs (closed vocab, no space-prefix), The Pile/BookCorpus/Reddit data (legal) | license + contract + legal filters |
| Tokenizer contract | space-prefixed word-start (`Ġ`/`▁`/BBPE) — **mandatory pre-flight** (`tokenizer_preflight.py`) | the `+0.5` lexicon boost and `lead_space` logic break silently otherwise |
| Server change | **Required**, not drop-in: rewrite BOS handling + special-bias-by-id + rebuild | **[OVERRIDE]** of "load unchanged" — verified false |
| Quant | **Q5_K_M default, Q8_0 if calibration drifts**; Q4_K_M only if eval proves it holds | **[OVERRIDE]** of "ship Q4_K_M first": a 360M model at Q8_0 is ~400 MB, already ~9× under Gemma — no footprint reason to take Q4's calibration hit |
| SFT/LoRA stack | **mlx-lm** (`mlx_lm.lora`) on-device | Apple-native, minutes on M2/M3 |
| Preference stack | **TRL `trl.experimental.kto` on a rented L4/A10/4090** (~$0.50/hr) for real KTO; **mlx-lm-lora DPO** on-device for synthetic pairs | KTO needs batch≥4 + sequential KL; MPS too slow |
| RL method | **KTO core** (unpaired binary = the data shape); synthetic-phase DPO where pairs exist | |
| RL gating | SFT + synthetic-DPO first; real KTO **only after ≥300–500 genuine (Tab/backtick) positives** | **[OVERRIDE]** of "200–500 total events": rejects dominate, so 300 events ≈ 30–60 positives |
| Privacy | public-data base (central) + **on-device LoRA only, zero upload** | federation/DP dropped from default |
| Conversion tooling | **must be stood up** — `vendor/llama.cpp` is headers-only (no `convert_hf_to_gguf.py`, no `llama-quantize`) | verified |
| Go/no-go meter | `training/eval.py` over the real server protocol | already built |

---

## 1. Phase 0 — on-device data-collection foundation  *(implemented)*

Capture is implemented in `TrainingLog.swift` + the completion loop: opt-in JSONL at
`~/Library/Application Support/typer/training.jsonl`, `0600`, OFF by default, skipped
during secure input / disabled apps / credential apps, context bounded to
`stableTail(context, max: 600)`, 8 MB rolling cap, wiped by "Reset All Data".

### 1.1 Schema (`schema_version: 2`, as shipped)

```jsonc
{
  "schema_version": 2,
  "ts": 1750000000.0,          // unix seconds at resolution
  "context": "…",              // immediate before-cursor text (screened; no folded background)
  "suggestion": "…",           // full suggestion shown
  "accepted": true,            // words_accepted > 0
  "accept_kind": "tab",        // tab | backtick | typethrough | none  ← de-confounds the reward
  "words_accepted": 3,
  "words_shown": 6,
  "confidence": 0.27,          // mean token prob the model reported
  "shown": true,               // false for exploration/suppressed rows
  "exploration": false,        // true = logged BELOW the gate (suppressed region)
  "min_conf": 0.22,            // effective gate at the time (policy tag)
  "max_words": 7,              // words requested for this generation
  "app_category": "chat",      // chat|email|docs|code|browser|other
  "source": "generate",        // generate|prefetch
  "model": "gemma-4-E2B-i1-Q4_K_M.gguf",  // policy/version tag
  "reason": "resolved"         // resolved|dismissed|suppressed
}
```

Key design choice: **`context` is the immediate typed text only**, never the assembled
prompt's folded-in window/clipboard/OCR blocks. That makes the corpus both more
privacy-scoped and more generalizable (it learns "continue this text", not "reproduce
this person's screen").

### 1.2 De-confounded reward capture *(implemented)*

`resolveCompletionOutcome(_:via:)` is the single universal resolution chokepoint (Tab,
backtick, type-through exhaust, divergence reject, Esc), so accepts and rejects are both
captured with the final consumed count **and** `accept_kind`. This is what lets the
trainer separate a real Tab accept (the user did not type those words) from a
type-through (they would have anyway). A safety flush in `clearSuggestion` covers
click/app-switch/paste abandonment; `noteSuppressed` logs gate-suppressed suggestions as
below-gate negatives so the dataset is not censored to gate-passing survivors.

### 1.3 Privacy + scrubbing *(implemented; one item pending)*

**[OVERRIDE]** of any "context == style.txt sensitivity" framing — the raw buffer is
strictly more sensitive, so it is filtered, not trusted:
- `TrainingLog.looksSensitive` drops any example whose context/suggestion contains a
  secret-shaped token (email, URL, ≥4-digit run, key-like token, filesystem path). The
  Python builder re-screens (`looks_sensitive`) as defense-in-depth.
- `TrainingLog.sensitiveAppBundles` skips capture entirely in password managers /
  Keychain / Passwords; secure-input and disabled-app gating already apply.
- Because `context` excludes the folded background blocks, on-screen clipboard/OCR text
  cannot leak through it.
- **TODO (M6):** "Reset All Data" deletes the source files but not a trained LoRA (which
  can memorize verbatim rare strings). Make Reset also delete/rebuild the adapter from the
  synthetic base. Shipped guarantee = "clear my data **and** the model that learned it."

### 1.4 Consent UX *(implemented)*

The toggle reads **"Record my typing to train a local model"** and, on enable, shows a
one-time sheet stating the data stays on this Mac, warning that context can include
anything typed, and offering inspect/erase. An **"Inspect training data…"** item opens
the file.

### 1.5 How the existing memories feed in

- **`style.txt`** (`category\ttext`): sliced by `build_dataset.py` into prefix→5–7-word
  SFT positives (real human continuations). Primary cold-start personalization.
- **`feedback.json`**: aggregate accept history → runtime `adjustedMaxWords()` /
  `confidenceAdjustment()`; **not** a training input, but its acceptance rate is the
  trigger for *when* a user has enough signal to retrain.
- **`lexicon.json`**: the runtime `+0.5` first-token boost; not a training input.

---

## 2. Phase 1 — datasets + synthetic data

**License posture:** central base training uses **public corpora only**; no user data
ever joins a central run.

### 2.1 Public seed mix (all clean: ODC-By / Apache / MIT / CC0 / public-domain)

| Register | Dataset | License | Pull | app_category |
|---|---|---|---|---|
| web/docs/browser | **FineWeb-Edu `sample-10BT`** | ODC-By | ~300 MB–2 GB subsample | docs/browser |
| web (supplement) | OpenWebText | CC0 | optional ~1 GB | browser |
| chat/IM | **OpenAssistant oasst1+oasst2**, English, trees flattened | Apache-2.0 | full (~150 MB) | chat |
| email | **Enron** (LoC mirror), PII-scrubbed | public-record | ~200 MB sampled | email |
| long-form | **Project Gutenberg / Common Pile v0.1** | PD / permissive | ~200 MB | docs |
| instruction→completion | **Dolly-15k** (CC-BY-SA, attribute) + non-NC Tulu-3 parts | CC-BY-SA / ODC-By | full | docs |

**Excluded outright:** The Pile/Books3 (litigation), BookCorpus (copyright), all
Reddit-derived incl. WritingPrompts source + Pushshift (post-2024 policy),
DailyDialog/AESLC/No-Robots (CC-BY-NC — fatal for a commercial app).

### 2.2 Conversion to the app's exact prompt format

`build_dataset.py --corpus DIR` already does this: each doc → plaintext → cut at word
boundaries → PREFIX (≤600-char window, `Writing app: <category>` header, live line last)
→ TARGET (next 5–7 words, truncated at sentence end, **leading-space prefixed**). It never
writes `<bos>` (the runtime prepends it; the *value* changes per model — §3.3).

### 2.3 Synthetic cold-start preferences *(implemented: `synth_negatives.py`)*

For each positive `(prompt → continuation)` it emits programmatic **negatives** matching
the server's own `looks_bad_completion`/suppression logic — echo, over-length, `<|`
special-token, mid-word-no-leading-space, generic filler, repeated word, truncated word —
as `dpo_synth.jsonl` pairs and `kto_synth.jsonl` rows. This teaches the runtime contracts
directly and, scored through the candidate model, calibrates the gate offline (so a
fresh, logging-off install ships calibrated). Optional later: 2–3 teacher models for
extra SFT positives (de-fingerprint + MinHash-LSH dedup). Target ~100–200k SFT pairs,
~20–50k synthetic preference pairs.

---

## 3. Phase 2 — base model + tokenizer decision

### 3.1 Qwen3-0.6B-Base (default), SmolLM2-360M-Base (fallback)

Both Apache-2.0, ship a true non-instruct base (**use `-Base`, never instruct** — chat
tokens collide with the special-bias ban and the plaintext continuation prompt), and
satisfy the contract:
- **Qwen3-0.6B-Base** — BBPE, vocab ~151k, no `<bos>`. Q5_K_M ≈ 0.4–0.5 GB. Best sub-1B
  calibration.
- **SmolLM2-360M-Base** — GPT-2 BPE (`Ġ`), vocab 49,152. Q5_K_M ≈ 0.25 GB, fastest first
  token, smallest softmax — pick if cold-prompt prefill at 0.6B fails the budget.

**[OVERRIDE]** default up to 0.6B: there is no evidence a 360M reproduces Gemma's
good/junk separation, and separation collapse can't be fixed by re-thresholding. Escalate
*down* only after eval proves it holds.

### 3.2 Tokenizer pre-flight (mandatory, every swap) — `tokenizer_preflight.py`

Asserts `" word"` → a single leading-space start token distinct from `"word"`, prints the
model's real BOS convention (to drive the server change), and lists the real special
tokens (to rebuild the ban list). Hard-fails a non-conforming base.

### 3.3 Required server changes (NOT a drop-in — TODO M1)

**[OVERRIDE]** of "load unchanged". Edit `scripts/llama_server.cpp` + rebuild:
1. **`prompt_complete()`**: stop string-prepending `"<bos>"`. Drive BOS off
   `llama_vocab_get_add_bos(vocab)` and `add_special=true` in `tokenize()` — for
   Qwen3-Base prepend nothing; for SmolLM2 handle `<|endoftext|>`. The literal `"<bos>"`
   tokenizes to junk bytes in non-Gemma vocabs → incoherent output.
2. **`init_biases()`**: rebuild the ban list **by token id** from the new vocab's actual
   special/added tokens, not by tokenizing Gemma-specific literal strings.
3. **Tooling gap**: `vendor/llama.cpp` is headers-only — clone a full llama.cpp into the
   conversion env for `convert_hf_to_gguf.py` + `llama-quantize` + `llama-tokenize`.

---

## 4. Phase 3 — training pipeline (end to end)

| Stage | Method | Command (Mac-native) | Data | Runtime |
|---|---|---|---|---|
| 3a. continued-pretrain/distill | — | **Skip in v1** — base is already prose-heavy; task is narrow | — | — |
| 3b. Cold-start SFT | LoRA, mask-prompt | `mlx_lm.lora --model Qwen/Qwen3-0.6B-Base --train --data ./data/mlx --fine-tune-type lora --mask-prompt --iters 600 --batch-size 4` | `sft.jsonl` | ~2–10 min, 2–4 GB, M2/M3 |
| 3c. Synthetic preference (0.5) | DPO/IPO | `mlx_lm_lora.train --train-mode dpo --beta 0.1` (on-device) | `dpo.jsonl` + `dpo_synth.jsonl` | ~10–40 min |
| 3d. Real preference RL | **KTO** | `trl.experimental.kto` on a rented L4/A10/4090 | `kto.jsonl` (de-confounded, §5) | <1 hr, ~$5 |
| 3e. Fuse + convert + quant | — | `mlx_lm.fuse` → `convert_hf_to_gguf.py --outtype f16` → `llama-quantize … Q5_K_M` | — | minutes |
| 3f. Calibrate + eval | — | `calibrate_gate.py` → set `min_confidence` → `eval.py` | held-out | minutes |

Quant: **Q5_K_M default**, Q8_0 if separation drifts, Q4_K_M only if eval proves it holds.
The `Makefile` wires these stages; deps are pinned in `pyproject.toml` (note: `trl` KTO
is experimental and `mlx-lm-lora` evolves — pin and re-verify flags).

---

## 5. Phase 4 — the RL recipe (in depth)

### 5.1 Method — KTO core
Typer's signal is **unpaired binary** (one suggestion per context, resolved
accept/reject) — KTO's (2402.01306) / BCO's (2404.04656) exact domain. DPO/IPO/ORPO need
`(chosen,rejected)` for the *same* prompt, which only the rare same-context-both-outcomes
case produces (`build_dataset.py` mines those into `dpo.jsonl`). PPO/GRPO rejected for the
on-device <1B core. Precedent: Zed's Zeta moved the needle with ~150 hand-curated examples.

### 5.2 De-confounded reward *(capture implemented; weighting in `build_dataset.py`)*
**[OVERRIDE]** `label = words_accepted > 0`:
- **Survivorship censoring** — capture sits *after* the adaptive gate, so naive KTO learns
  `P(accept | shown ∧ conf>bar)`. Mitigated now by `noteSuppressed` (below-gate negatives
  with true confidence). The stronger fix — an opt-in ε-path that occasionally *shows*
  below-gate suggestions to get real accepts there — is **TODO (M7)**.
- **Type-through == plausibility** — `accept_kind` separates Tab/backtick (real gain) from
  type-through; `build_dataset.classify()` treats Tab/backtick + long type-through as
  positive and **drops short type-throughs as zero-information** (neither reward nor SFT).
- **Information-gain weighting** — KTO rows carry a `weight ≈ words inserted`; below-gate
  exploration rows are weak negatives.
- **Synthetic negatives** from `synth_negatives.py` injected as extra `label:false`.

### 5.3 Reward-hacking guards
Short ` the`/` and` neutralized by the accept_kind rule; genericness handled by
info-gain weighting + generic-filler negatives; **length exploitation** — KTO has no length
normalization, so cap completion length in data and keep the server's `limit_words`; **never
make confidence a training objective** (keep it a recalibrated gate + ECE monitor);
easy-context skew → BCO-UDM only if observed, else stratify by `app_category` once each
stratum has positives.

### 5.4 Confidence calibration — `calibrate_gate.py`
`confidence` is exactly what KTO shifts, so **recalibrate `min_confidence` per model
version**. **[OVERRIDE]** "just tuning": separation (AUC) is a **hard model-selection
gate** — if a candidate can't separate real accepts from corrupted negatives, escalate
360M→0.6B rather than ship a non-discriminating gate. Calibrating from real user logs is
**forbidden as the default**; the Phase-0.5 synthetic calibration is mandatory.

### 5.5 Cold-start, loop, thresholds
Phase 0 (SFT) + Phase 0.5 (synthetic) need no user data — always first. **[OVERRIDE]** gate
the first real KTO on **≥300–500 genuine positives**, not total events; robust at ~1–2k.
Keep desirable:undesirable 1:1..4:3; lr 5e-7..5e-6, add epochs not lr. Loop: deploy →
log (opt-in, redacted, policy-tagged) → retrain → recalibrate gate → **A/B vs previous on a
frozen set of genuine accepts**, promote only on a win there. Pin `trl.experimental`;
re-run the tokenizer pre-flight on every fuse.

---

## 6. Phase 5 — generalization + privacy

**Hard program constraint:**
> **DEFAULT = public-data synthetic base (central, no user data) + on-device-only
> personalization (LoRA/KTO on local logs, never uploaded).**

The app has *zero* network code today; the architecture must preserve that.
- **Shared synthetic base** — trained centrally on public corpora only, de-fingerprinted,
  ships with the app.
- **On-device LoRA** — per-user SFT+KTO on local redacted logs, never uploaded; trains only
  on AC/idle.
- **Federated/aggregation — not in v1.** **[OVERRIDE]** DP-SGD/SecAgg/DP-FTRL are incoherent
  for a single user's LoRA. If ever built: opt-in, own consent, uploads only clipped/
  DP-noised LoRA deltas under SecAgg, **stated minimum cohort (≥~1k–10k)** + per-user ε,
  never `context`/raw logs/`style.txt`. Below cohort size, don't ship it or claim DP.

---

## 7. Eval + acceptance criteria — `training/eval.py`

Offline: perplexity (sanity floor); **next-chunk match** (first-word acc + avg
matched-words, the type-through proxy); **held-out acceptance proxy** (`shown` rate, and
`shown` separation between real accepts and corrupted negatives). On-device: ttfp p90 on a
**cold prompt (cache-miss, full ~1500-token prefill)**, not just warm — prefill, not
decode, is the risk at 0.6B/large vocab. Targets: **ttfp p50 < 100 ms, resident RAM
< 150 MB** (vs Gemma ~400 MB+), **disk < 0.6 GB** (vs 3.5 GB).

**Go/no-go to swap (all on `eval.py`):**
1. Tokenizer pre-flight passes (single leading-space start token). *(hard fail otherwise)*
2. Confidence **separation** preserved (AUC ≈ Gemma's; `calibrate_gate.py`). If 360M fails,
   escalate to 0.6B.
3. First-word acc ≥ Gemma on the same held-out set; matched-words ≥ Gemma.
4. Cold-prompt ttfp p90 within budget (< ~120 ms).
5. Server BOS + special-bias edits in place and rebuilt; output coherent.
6. Quant = Q5_K_M (or Q8_0); Q4 only if 1–4 still hold.

Always run the **untuned** candidate through `eval.py` first for a real floor — quality is
measured, not inferred from license/tokenizer fit.

---

## 8. Milestone roadmap

| # | Milestone | Effort | Compute | Artifact |
|---|---|---|---|---|
| ✅ M-data | Capture (schema v2), builder, synth negatives, calibrate, preflight, eval | done | — | this repo's `training/` + capture |
| M0 | Stand up conversion toolchain (full llama.cpp); convert untuned Qwen3-0.6B + SmolLM2-360M → Q5_K_M | 0.5 d | local | 2 baseline GGUFs |
| M1 | **Server change**: `prompt_complete()` BOS + `init_biases()` by-id + rebuild; run preflight | 1 d | local | patched server |
| M2 | **Untuned floor**: `eval.py` both baselines vs Gemma; pick base | 0.5 d | local M-series | floor numbers + base decision |
| M3 | Public + synthetic data: `build_dataset.py --corpus` + `synth_negatives.py` (+ optional teacher) | 2 d | optional GPU | `sft/kto/dpo*.jsonl` |
| M4 | **Cold-start SFT** + **synthetic DPO/KTO**; fuse → Q5_K_M | 1 d | local M-series | candidate GGUF |
| M5 | **Offline gate calibration** (synthetic good/junk → `calibrate_gate.py`); `eval.py` go/no-go | 1 d | local | **shippable v1 base** |
| M6 | Reset-also-deletes-LoRA; periodic retrain-from-current-data | 1 d (Swift) | — | forgetting guarantee |
| M7 | ε-exploration *showing* path (opt-in) | 1 d | — | suppressed-region accept coverage |
| M8 | Collect **≥300–500 genuine positives** → **real KTO** on rented GPU → A/B vs base on frozen accepts → promote on win | ongoing + 0.5 d/retrain | ~$5/retrain | on-device LoRA v_n |
| M9 | Deploy→collect→retrain loop wired to the acceptance trigger | 1 d | local + occasional GPU | self-improving loop |

**Total to shippable base (M0–M5): ~6 days + a few $ of GPU.**

---

### Key files
`scripts/llama_server.cpp` (BOS `prompt_complete`, `init_biases`, `token_prob`) ·
`scripts/typer/TrainingLog.swift` (schema v2, `looksSensitive`, `sensitiveAppBundles`) ·
`scripts/typer/TyperApp+Completion.swift` (`noteTraining`/`flushTrainingOutcome`/
`noteSuppressed`, gate) · `scripts/typer/TyperApp+EventTap.swift` (accept kinds) ·
`training/build_dataset.py` · `training/synth_negatives.py` · `training/calibrate_gate.py` ·
`training/tokenizer_preflight.py` · `training/eval.py` · `config.example.toml`
(`min_confidence`, `training_log_enabled`) · `vendor/llama.cpp` (headers-only).
