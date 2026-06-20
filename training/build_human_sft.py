#!/usr/bin/env python3
"""Assemble the human-grounded tiers into an mlx-lm "text" SFT set, with per-tier control.

The data pipeline produces four provenance tiers (research post §6):

  authentic   real human continuations — direct elicitation + mined capture + candidate picks.
              The gold signal; everything else exists to scale it. Oversampled.
  human-var   teacher variations anchored to a real continuation (preserve register/length).
  synth       from-scratch synthetic continuations (ordinary + curt internet "genz" voice).
  synth-var   teacher explosion of the synth base — large, lowest authenticity.

This script is the ablation lever: pick which tiers go in, how hard authentic is oversampled,
and (per tier) a random cap, then emit mlx text format. Build several mixes, train each at a
matched config, and eval_compare decides which tiers earn their place.

Screens mirror build_distill_sft.py (length 1..max-words, must contain alnum, no degenerate
repetition). Identical completion strings in the NON-authentic tiers are capped so common
continuations (" the ...") don't swamp diversity; authentic rows are never dropped or capped.
A small general-prose replay anchor (true next-words from sft.jsonl, prompts disjoint) resists
catastrophic forgetting of the base.

  uv run build_human_sft.py --out-mlx data/mlx_grounded \
      --authentic ../data/human_golds.jsonl --authentic ../data/capture_golds.jsonl \
      --authentic ../data/authentic_golds.jsonl --authentic-oversample 8 \
      --tier human-var:../data/human_grounded_authentic.jsonl \
      --tier synth:../data/human_synth_all.jsonl \
      --tier synth-var:../data/human_grounded_synth.jsonl:25000 \
      --replay-src data/sft.jsonl --replay-frac 0.08
"""
from __future__ import annotations

import argparse
import json
import random
import re
from collections import Counter
from pathlib import Path


def words(s: str) -> list[str]:
    return s.split()


def is_degenerate(comp: str) -> bool:
    w = [x.lower() for x in comp.split()]
    if len(w) >= 3:
        for i in range(len(w) - 2):                 # same token 3x in a row
            if w[i] == w[i + 1] == w[i + 2]:
                return True
    if len(w) >= 4:                                 # repeated bigram loop (a b a b)
        for i in range(len(w) - 3):
            if w[i] == w[i + 2] and w[i + 1] == w[i + 3]:
                return True
    return False


def load(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]


def screen(rows: list[dict], max_words: int) -> tuple[list[dict], Counter]:
    """Length / content / repetition screen. Returns kept rows + a drop tally."""
    kept, drops = [], Counter()
    for o in rows:
        comp = o.get("completion", "")
        nw = len(words(comp))
        if nw < 1 or nw > max_words:
            drops["len"] += 1; continue
        if not any(ch.isalnum() for ch in comp):    # " ." and friends — zero info
            drops["empty"] += 1; continue
        if is_degenerate(comp):
            drops["repetition"] += 1; continue
        kept.append(o)
    return kept, drops


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-mlx", type=Path, required=True)
    ap.add_argument("--authentic", type=Path, action="append", default=[],
                    help="real-human file (repeatable); these are oversampled and never dropped")
    ap.add_argument("--authentic-oversample", type=int, default=8,
                    help="repeat the (deduped) authentic pool this many times")
    ap.add_argument("--tier", action="append", default=[], metavar="name:path[:cap]",
                    help="non-authentic tier (repeatable); optional integer cap = random subsample")
    ap.add_argument("--replay-src", type=Path, default=Path("data/sft.jsonl"))
    ap.add_argument("--replay-frac", type=float, default=0.08,
                    help="general-prose replay as a fraction of the assembled mix")
    ap.add_argument("--max-words", type=int, default=12)
    ap.add_argument("--dedup-cap", type=int, default=6,
                    help="max repeats of an identical completion string within the non-authentic tiers")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    manifest: dict[str, int] = {}

    # --- authentic: dedup exact (prompt, completion), then oversample. Never screened out
    #     for confidence; we DO apply the same length/repetition screen for safety.
    auth_raw: list[dict] = []
    for p in args.authentic:
        auth_raw += load(p)
    auth_seen = set(); auth_unique = []
    for o in auth_raw:
        key = (o.get("prompt", ""), o.get("completion", ""))
        if key in auth_seen:
            continue
        auth_seen.add(key); auth_unique.append(o)
    auth_kept, auth_drops = screen(auth_unique, args.max_words)
    authentic = auth_kept * max(1, args.authentic_oversample)
    manifest["authentic_unique"] = len(auth_kept)
    manifest["authentic_emitted"] = len(authentic)

    # --- non-authentic tiers: screen, optional cap, then dedup-cap identical completions
    #     ACROSS all such tiers together so no single completion string dominates.
    tier_rows: list[dict] = []
    for spec in args.tier:
        name, _, rest = spec.partition(":")
        path_str, _, cap_str = rest.partition(":")
        rows = load(Path(path_str))
        kept, _ = screen(rows, args.max_words)
        if cap_str:
            cap = int(cap_str)
            if len(kept) > cap:
                rng.shuffle(kept); kept = kept[:cap]
        for o in kept:
            o["_tier"] = name
        tier_rows += kept
        manifest[f"tier:{name}"] = len(kept)

    rng.shuffle(tier_rows)
    comp_seen = Counter(); tier_deduped = []; drop_dup = 0
    for o in tier_rows:
        c = o.get("completion", "").strip().lower()
        if comp_seen[c] >= args.dedup_cap:
            drop_dup += 1; continue
        comp_seen[c] += 1; tier_deduped.append(o)
    manifest["tier_after_dedup"] = len(tier_deduped)

    mix = authentic + tier_deduped
    mix_prompts = {o.get("prompt", "") for o in mix}

    # --- replay anchor: raw general continuations, prompts disjoint from the mix
    replay = []
    if args.replay_frac > 0 and args.replay_src.exists():
        pool = []
        for l in args.replay_src.read_text(encoding="utf-8").splitlines():
            l = l.strip()
            if not l:
                continue
            o = json.loads(l)
            if o.get("prompt") and o.get("completion") and o["prompt"] not in mix_prompts:
                pool.append({"prompt": o["prompt"], "completion": o["completion"]})
        rng.shuffle(pool)
        replay = pool[: int(len(mix) * args.replay_frac)]
    manifest["replay"] = len(replay)

    mix += replay

    # --- emit mlx "text" format (the exact inference string), 90/10 train/valid
    rows = [json.dumps({"text": (o.get("prompt", "") + o.get("completion", "")).strip()},
                       ensure_ascii=False) + "\n"
            for o in mix if (o.get("prompt", "") + o.get("completion", "")).strip()]
    rng.shuffle(rows)
    args.out_mlx.mkdir(parents=True, exist_ok=True)
    k = max(1, len(rows) // 10)
    (args.out_mlx / "valid.jsonl").write_text("".join(rows[:k]), encoding="utf-8")
    (args.out_mlx / "train.jsonl").write_text("".join(rows[k:]), encoding="utf-8")
    (args.out_mlx / "manifest.json").write_text(
        json.dumps({**manifest, "total_rows": len(rows), "train": len(rows) - k, "valid": k,
                    "seed": args.seed, "authentic_oversample": args.authentic_oversample},
                   indent=2), encoding="utf-8")

    print(f"authentic: {manifest['authentic_unique']} unique x{args.authentic_oversample} "
          f"= {manifest['authentic_emitted']}  (screen drops: {dict(auth_drops)})")
    for k2, v in manifest.items():
        if k2.startswith("tier:"):
            print(f"  {k2}: {v}")
    print(f"tier dedup-cap removed: {drop_dup}  -> {manifest['tier_after_dedup']} kept")
    print(f"replay anchor: {len(replay)} ({args.replay_frac:.0%})")
    print(f"-> mlx text: train {len(rows)-k}  valid {k}  @ {args.out_mlx}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
