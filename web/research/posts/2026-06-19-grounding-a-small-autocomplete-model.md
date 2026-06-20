---
slug: grounding-a-small-autocomplete-model
title: Grounding a Small On-Device Autocomplete Model in Human Writing
date: 2026-06-19
authors: The Typer Project
abstract: >
  Typer is an on-device autocomplete system for macOS built on a sub-1B language model.
  This report documents the methodology behind a recent revision: a register-faithful
  evaluation, the isolation of the inference harness as a confound, the selection of a
  distillation teacher by direct measurement, a comparison of full fine-tuning against
  low-rank adaptation, and a pipeline that grounds the training distribution in real human
  writing rather than model-generated prose. On a 180-example benchmark drawn from the
  registers users actually type in, the Claude-distilled 0.6B model improves over its
  Gemma-distilled predecessor, and a community full fine-tune reaches 35% first-word
  accuracy, two points below the Claude Haiku teacher. We are explicit about the limits: a
  capacity ceiling at 0.6B, a benchmark small enough that sub-three-point differences are
  noise, a mis-calibrated confidence gate, and the unresolved question of whether full
  fine-tuning can surpass adaptation given adequate training. The hypothesis under test is
  that, for a model this size, the dominant lever is the authenticity of the training data.
---

## 1. Problem setting

Autocomplete that runs on the user's machine operates under constraints a hosted system does not. The model must fit in a fraction of system memory, return the first token of a suggestion in roughly 100 ms, and never send keystrokes off the device. These constraints favor a small model, on the order of 0.6 billion parameters, quantized to a few hundred megabytes. The cost of smallness is capacity. A model this size cannot be relied upon to discover good continuations unaided, and its behavior is unusually sensitive to two things that are easy to overlook: the data it is trained on, and the decoding procedure applied at inference.

The product goal compounds the difficulty. A personal autocomplete is valuable in proportion to how closely its suggestions resemble what the specific user would have typed. That target is idiosyncratic and non-stationary, and it is not well approximated by any fixed public corpus. Much of what follows is a consequence of taking that statement seriously.

## 2. Measurement

Earlier development evaluated the model on held-out prose drawn from encyclopedic and documentation corpora. This produced stable numbers that failed to predict in-product behavior, because the evaluation distribution and the deployment distribution are different. Text typed into chat clients, code editors, terminals, and search fields is shorter, less grammatical, more elliptical, and register-specific in ways that formal prose is not. Optimizing against prose was optimizing against the wrong objective.

We constructed a benchmark of 180 examples sampled from the registers the product actually sees: partial chat messages, code mid-line, commit messages, the opening of an email, search queries, and notes. Each example is a context truncated at a plausible mid-utterance point together with a gold continuation of the next few words.

We report two metrics. First-word accuracy is the fraction of examples for which the model's first suggested word matches the gold first word after lowercasing and stripping surrounding punctuation. For predictions $\hat{y}_i$ and golds $y_i$,

$$\mathrm{FW} = \frac{1}{N}\sum_{i=1}^{N} \mathbb{1}\!\left[w_1(\hat{y}_i) = w_1(y_i)\right],$$

where $w_1(\cdot)$ extracts the normalized first word. Type-through length is the mean number of leading words that match before the first divergence,

$$\mathrm{TT} = \frac{1}{N}\sum_{i=1}^{N} \max\{\,k : \hat{y}_{i,1:k} = y_{i,1:k}\,\},$$

which estimates how far a user could follow a suggestion by typing along it. First-word accuracy measures whether the system should show anything at all; type-through length measures how much value a shown suggestion delivers.

## 3. The harness as a confound

Typer does not present raw model output. A harness sits between the model and the screen: a sampler with tuned temperature and nucleus parameters, a repetition penalty, removal of echoed context, suppression of mid-word continuations, and a confidence gate that withholds low-probability suggestions. We had treated this harness as fixed and attributed all measured quality to the model.

To test that assumption we added a raw decoding path to the inference server and scored identical weights with and without the harness. On the typed benchmark, greedy decoding of the raw model exceeded the tuned nucleus sampler in both first-word accuracy and type-through length. The harness had been calibrated against an earlier model and was now subtracting accuracy from a stronger one. We changed the default sampler to greedy, which recovered most of the difference and was neutral to slightly positive for the previous model. The general point is that any evaluation of an on-device model that scores only the full pipeline conflates the model with its harness, and the two must be measured apart before either can be improved.

The signal the gate uses is the mean probability the model assigned to its own sampled tokens,

$$c = \frac{1}{n}\sum_{t=1}^{n} p_\theta\!\left(x_t \mid x_{<t}\right).$$

On the typed benchmark the current threshold admits almost every suggestion while only about a third of admitted suggestions are useful. That pattern indicates the threshold was fit to a distribution unlike deployment. Recalibration is outstanding work and is treated as such below.

## 4. Teacher selection

A 0.6B model is trained by sequence-level knowledge distillation: a stronger teacher labels a set of contexts with completions, and the student learns to reproduce them. The teacher therefore bounds the student, and its choice should be made by measurement rather than convenience. Typer originally distilled from Gemma, the 3.5 GB model the product shipped with.

We evaluated candidate teachers directly on the typed benchmark by having each label held-out contexts under matched conditions. Gemma reached 31% first-word accuracy. Claude Haiku reached 37% and Claude Sonnet 43%. We relabeled the distillation contexts with Claude through the Message Batches API and trained the student on the result, filtering teacher outputs that break character into an assistant register, which would otherwise teach the student to emit chatbot text.

Deployment uses an online comparison rather than an offline promotion decision. Two students serve in parallel, each receiving a share of traffic, and each resolved suggestion pays a graded reward to the model that produced it:

$$r = \begin{cases} 1.0 & \text{explicit accept} \\ \min(1,\ 0.25\,w) & \text{type-through of } w \text{ words} \\ 0 & \text{shown and ignored.} \end{cases}$$

Share shifts toward the higher-reward arm and locks when one arm crosses a threshold. The Claude-distilled student is currently taking about 60% of traffic from the Gemma-distilled one, which corroborates the offline ranking under live use.

```chart
{"type":"bar","title":"First-word accuracy on the typed benchmark (n = 180)","unit":"%","note":"on-device models are 0.6B; cloud models shown as an upper reference","data":[{"label":"Gemma 3.5 GB","value":31},{"label":"Gemma-distill 0.6B","value":28},{"label":"Claude-distill 0.6B","value":31},{"label":"full-FT (Claude data)","value":28},{"label":"v1 full-FT","value":35,"highlight":true},{"label":"Haiku (cloud)","value":37},{"label":"Sonnet (cloud)","value":43}]}
```

## 5. Full fine-tuning versus adaptation

The students above are low-rank adapters over a frozen base. A community contribution instead fully fine-tuned the base, updating all parameters on the supervised set. That model, denoted v1, reached 35% first-word accuracy and 0.61 type-through, the strongest on-device result, two points below the Haiku teacher.

Motivated by this, we ran the symmetric experiment: a full fine-tune on the Claude-distilled data. It underperformed both v1 and the low-rank Claude student, reaching 28%. The most likely explanation is under-training. A full fine-tune updates roughly an order of magnitude more parameters than a rank-32 adapter, and at the conservative learning rate and the 1.6 epochs we used it did not converge; training loss plateaued above the adapter's. We have not yet run the longer, higher-rate schedule that would settle whether full fine-tuning surpasses adaptation on this data. We record this as an open and consequential question rather than a resolved comparison.

## 6. The data problem

The preceding results establish that teacher quality transfers to the student and that decoding matters. They leave the central difficulty untouched. Distillation data is written by a language model, and a model trained on the output of another model inherits that model's register, which is not the register of a particular person at a keyboard. For a generic autocomplete this is tolerable. For a personal one it is the failure mode, because the value of the product is proportional to how closely it reproduces the user. The remedy is to ground the training distribution in real human writing.

The pipeline draws on three sources. The first is direct elicitation: an interactive session presents register-faithful contexts and records the user's own continuation, optionally seeded by a few candidate options to lower the effort of contributing. The second is local capture: Typer already records on the device the suggestions a user accepts or types through, and those accepted continuations are real human selections. We mine them under a privacy filter that drops any row matching an email address, URL, phone number, long digit sequence, file path, handle, or key-like token, and nothing leaves the machine unscreened. The third is teacher-assisted expansion: for each real continuation, a teacher writes close variations that preserve the user's register, length, and informality, multiplying a few hundred authentic examples into tens of thousands without inventing new content. To probe breadth we additionally generated synthetic continuations in two deliberately different voices, one matching the user's ordinary register and one a curt, informal internet register, with every example tagged by provenance so its contribution can be measured and removed if it does not help.

This design carries a clear risk, which we state rather than bury. Teacher-assisted expansion and synthetic generation reintroduce model-written text, the very thing the pipeline exists to avoid. We mitigate by anchoring every expansion to a real continuation, by filtering hard for register and length, and by retaining provenance so that an ablation can quantify the marginal value of each source against the typed benchmark. Whether the synthetic tiers help or harm is an empirical question we have not yet answered.

## 7. Results

All on-device models are 0.6B and quantized; the cloud models are an upper reference, not a deployment option.

| Model | Size | First-word | Type-through |
|---|---|---|---|
| Gemma-4-E2B (original) | 3.5 GB | 31% | 0.51 |
| Gemma-distilled 0.6B | 0.6 GB | 28% | 0.47 |
| Claude-distilled 0.6B | 0.6 GB | 31% (raw) | 0.53 |
| Full fine-tune on Claude data | 0.6 GB | 28% | 0.46 |
| **v1, full fine-tune** | 0.6 GB | **35%** | **0.61** |
| Claude Haiku (reference) | cloud | 37% | 0.59 |
| Claude Sonnet (reference) | cloud | 43% | 0.72 |

The harness change is most visible as the gap between a model's raw and served numbers. For the strongest small model the served path now tracks the raw path closely; for earlier models the tuned sampler had been suppressing the model's own output.

```chart
{"type":"bar","title":"Harness vs. raw decoding, first-word accuracy","unit":"%","series":["raw (greedy)","served (harness)"],"data":[{"label":"Gemma-distill 0.6B","values":[28,28]},{"label":"Claude-distill 0.6B","values":[31,29]},{"label":"v1 full-FT","values":[32,35]}]}
```

## 8. Limitations and threats to validity

**Capacity.** The student trails the teacher by roughly six points (31 against 37), and the gap is structural. A fraction of teacher skill does not survive compression to 0.6B, and no amount of better data removes that ceiling, only how close we get to it.

**Statistical power.** The benchmark has 180 examples. The standard error on a proportion near 0.3 is about 3.4 points, so differences smaller than that are not distinguishable from noise. The v1 margin over the distilled students sits near this boundary; the type-through gaps are more robust than the first-word gaps.

**Construct validity.** The benchmark is one team's construction of plausible typing. It is not a random sample of any population's keystrokes, and register coverage is uneven, with shell and search under-represented.

**Gate calibration.** The confidence gate is fit to the wrong distribution and currently filters little. The reported first-word numbers are computed before the gate and are therefore unaffected, but in-product precision is not, and a user sees the gate's output, not the benchmark's.

**Personalization scope.** Human grounding is, so far, single-user. Whether the approach generalizes across users, and how much per-user data it requires, is untested.

**Synthetic contamination.** As stated in Section 6, expansion and the synthetic tiers may dilute authenticity. The ablation that would quantify this is pending, and until it is run the synthetic data is a hypothesis, not a result.

## 9. Future work

Train on the human-grounded set and ablate the provenance tiers against the typed benchmark, keeping only the sources that earn their place. Run the longer, higher-rate full fine-tune that would resolve the full-versus-adapter question. Recalibrate the confidence gate on the deployment distribution. Incorporate the live preference signal that the deployment race already collects into a preference-optimization stage, so the model adapts to the individual user over time rather than only at training time.

## 10. Reproducibility

The evaluation harness, the distillation and data-generation scripts, and the training pipeline are open source under [`training/`](https://github.com/frgmt0/typer/tree/main/training), and the inference server is [`scripts/llama_server.cpp`](https://github.com/frgmt0/typer/blob/main/scripts/llama_server.cpp). The benchmark construction, the raw-decoding path, the teacher batch labeling, the capture mining, and the expansion are each a separate, runnable component. Everything described here runs on a single Apple Silicon laptop, under a memory cap, and nothing user-derived leaves the device.
