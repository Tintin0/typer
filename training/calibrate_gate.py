#!/usr/bin/env python3
"""Re-fit Typer's min_confidence gate for a model, and decide if the gate even works.

The ~0.22 gate (TyperConfig.minConfidence) was fit to Gemma-3n's probability scale; a
different base produces a different scale AND a different good-vs-junk SEPARATION. The
feasibility review made this a MODEL-SELECTION gate, not a tuning footnote: if a 360M
model can't separate real accepts from junk by mean-token-probability, no threshold
recovers it and you should escalate to a larger base (e.g. Qwen3-0.6B).

Input: a JSONL of {"confidence": float, "good": bool} — either
  - data/calib.jsonl  (emitted by build_dataset.py from real shown suggestions), or
  - a synthetic set you scored by running the candidate model over good/bad pairs.

It reports:
  separation (AUC)  how well confidence ranks good above junk. ~0.5 = useless gate
                    (ESCALATE the model); >=0.70 = usable; >=0.80 = strong.
  recommended gate  the threshold maximizing coverage while holding precision>=target,
                    i.e. "show as much as possible without showing junk".
  the precision/coverage curve so you can pick your own operating point.

Stdlib only. Run: `uv run training/calibrate_gate.py --data training/data/calib.jsonl`.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def auc(scores_good: list[float], scores_bad: list[float]) -> float:
    """Probability a random good outranks a random bad (Mann–Whitney U / ROC-AUC)."""
    if not scores_good or not scores_bad:
        return float("nan")
    wins = 0.0
    for g in scores_good:
        for b in scores_bad:
            wins += 1.0 if g > b else (0.5 if g == b else 0.0)
    return wins / (len(scores_good) * len(scores_bad))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=Path(__file__).parent / "data" / "calib.jsonl")
    ap.add_argument("--target-precision", type=float, default=0.6,
                    help="min fraction of SHOWN suggestions that should be good")
    ap.add_argument("--min-good", type=int, default=30, help="refuse to fit below this many positives")
    args = ap.parse_args()

    if not args.data.exists():
        print(f"no calibration data at {args.data}. Use the app with capture on, or score a synthetic set.")
        return 2

    good, bad = [], []
    for line in args.data.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        c = float(o.get("confidence", 0.0))
        (good if o.get("good") else bad).append(c)

    n = len(good) + len(bad)
    print(f"examples: {n}  (good {len(good)}, junk {len(bad)})")
    if len(good) < args.min_good or len(bad) < args.min_good:
        print(f"not enough signal yet (need >= {args.min_good} of each). Collect more, or score a synthetic set.")
        return 1

    a = auc(good, bad)
    print(f"separation (AUC): {a:.3f}  -> ", end="")
    if a < 0.6:
        print("USELESS — confidence barely ranks good above junk. ESCALATE the base model;")
        print("                   do NOT ship this size hoping the adaptive layer compensates.")
    elif a < 0.7:
        print("WEAK — marginal gate; consider a larger base or rely less on the gate.")
    elif a < 0.8:
        print("USABLE.")
    else:
        print("STRONG.")

    # Sweep thresholds; for each, coverage = fraction shown, precision = good among shown.
    thresholds = sorted({round(c, 3) for c in good + bad})
    rows = []
    for t in thresholds:
        shown_good = sum(1 for c in good if c >= t)
        shown_bad = sum(1 for c in bad if c >= t)
        shown = shown_good + shown_bad
        if shown == 0:
            continue
        precision = shown_good / shown
        coverage = shown / n
        rows.append((t, precision, coverage))

    # Recommended gate: highest coverage with precision >= target.
    ok = [r for r in rows if r[1] >= args.target_precision]
    rec = max(ok, key=lambda r: r[2]) if ok else None
    print("\n  gate   precision  coverage")
    for t, p, cov in rows:
        mark = "  <= recommended" if rec and t == rec[0] else ""
        print(f"  {t:<6.3f} {p:>7.2f}   {cov:>7.2f}{mark}")
    if rec:
        print(f"\nRecommended min_confidence = {rec[0]:.3f}  "
              f"(precision {rec[1]:.2f}, shows {rec[2]*100:.0f}% of suggestions)")
        print("Set it in ~/Library/Application Support/typer/config.toml and re-run eval.py.")
    else:
        print(f"\nNo threshold reaches precision {args.target_precision}. The model can't be made "
              "precise by gating alone — improve the model (more SFT/preference) or escalate size.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
