#!/usr/bin/env python3
"""Merge fleet shards into one clean training file: dedup + slop/length filter + a quality report.

Each synth fleet (collect_human_data style or the gen-z fleet) writes per-agent shards. This folds
a set of shard dirs together, drops exact dupes and anything that reads like AI-slop or runs too
long, and reports the register/src/cell spread so we can see what we actually got.

  uv run training/merge_synth.py --dirs ../data/human_synth --out ../data/human_synth.jsonl
"""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

from expand_human_data import SLOP_OPENERS, SLOP_ANYWHERE


def ok(comp: str, max_words: int) -> bool:
    t = (comp or "").strip()
    if not t or not any(c.isalnum() for c in t):
        return False
    low = t.lower()
    if any(low.startswith(s) for s in SLOP_OPENERS) or any(s in low for s in SLOP_ANYWHERE):
        return False
    return len(t.split()) <= max_words


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dirs", nargs="+", required=True, help="shard dirs to merge")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--max-words", type=int, default=8)
    ap.add_argument("--sample", type=int, default=12)
    args = ap.parse_args()

    seen, rows = set(), []
    dropped_bad = dropped_dup = 0
    for d in args.dirs:
        for shard in sorted(Path(d).glob("*.jsonl")):
            for line in shard.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                p, c = o.get("prompt"), o.get("completion")
                if not p or not c or not ok(c, args.max_words):
                    dropped_bad += 1
                    continue
                key = (p, c.strip().lower())
                if key in seen:
                    dropped_dup += 1
                    continue
                seen.add(key)
                rows.append(o)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as f:
        for o in rows:
            f.write(json.dumps(o, ensure_ascii=False) + "\n")

    src = collections.Counter(o.get("src") for o in rows)
    reg = collections.Counter(o.get("register") for o in rows)
    print(f"kept {len(rows)}  ·  dropped {dropped_bad} (slop/long) + {dropped_dup} (dup)  -> {args.out}")
    print("by src     :", dict(src))
    print("by register:", dict(reg))
    print("\nsample:")
    import random
    for o in random.Random(0).sample(rows, min(args.sample, len(rows))):
        ctx = o["prompt"].split("\n\n", 1)[-1]
        print(f"  [{o.get('register')}] …{ctx[-40:]!r} -> {o['completion']!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
