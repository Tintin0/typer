#!/usr/bin/env python3
"""Turn raw teacher-distilled pairs into a filtered, replay-anchored SFT set for the student.

Implements the two recipes the research pass landed on:

  Filtering (seq-KD: filtering is the highest-ROI lever) --
    - length screen: keep autocomplete-shaped completions (1..MAX_WORDS words)
    - repetition screen: drop degenerate teacher outputs (repeated token / bigram loops)
    - dedup cap: a given completion string may appear at most DEDUP_CAP times, so common
      continuations (" the ...") don't swamp the set and diversity is preserved
    - confidence: keep the top CONF_KEEP fraction by the teacher's own confidence

  Replay anchor (anti-forgetting: ~10% general data stops the base from drifting) --
    mixes REPLAY_FRAC of raw general-corpus continuations (true next-words, NOT distilled)
    drawn from sft.jsonl, with prompts disjoint from the distilled set.

Writes mlx-lm "text" format (prompt+completion joined, the exact inference string) to
--out-mlx/{train,valid}.jsonl (90/10), plus a manifest of what went in.

  uv run build_distill_sft.py --gold data/distill_gold.jsonl --replay-src data/sft.jsonl \
      --out-mlx data/mlx_distill --conf-keep 0.7 --replay-frac 0.1
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gold", type=Path, required=True)
    ap.add_argument("--replay-src", type=Path, default=Path("data/sft.jsonl"))
    ap.add_argument("--out-mlx", type=Path, required=True)
    ap.add_argument("--conf-keep", type=float, default=0.7, help="keep top fraction by teacher_conf")
    ap.add_argument("--corpus-cap", type=int, default=0,
                    help="cap corpus(prose)-src pairs (keep highest-conf) to rebalance toward "
                         "the register distribution; 0 = no cap")
    ap.add_argument("--replay-frac", type=float, default=0.1, help="general-prose replay as frac of kept gold")
    ap.add_argument("--max-words", type=int, default=12)
    ap.add_argument("--dedup-cap", type=int, default=5, help="max repeats of an identical completion string")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    gold = [json.loads(l) for l in args.gold.read_text(encoding="utf-8").splitlines() if l.strip()]
    n0 = len(gold)

    # 1) length + repetition + content screen
    kept = []
    drop_len = drop_rep = drop_empty = 0
    for o in gold:
        comp = o["completion"]
        nw = len(words(comp))
        if nw < 1 or nw > args.max_words:
            drop_len += 1; continue
        if not any(ch.isalnum() for ch in comp):      # " ." and friends — zero info
            drop_empty += 1; continue
        if is_degenerate(comp):
            drop_rep += 1; continue
        kept.append(o)

    # 2) dedup cap on identical completion strings (preserve diversity)
    seen = Counter(); deduped = []; drop_dup = 0
    for o in sorted(kept, key=lambda r: -r.get("teacher_conf", 0)):   # keep highest-conf copies
        c = o["completion"].strip().lower()
        if seen[c] >= args.dedup_cap:
            drop_dup += 1; continue
        seen[c] += 1; deduped.append(o)

    # 3) confidence: keep top conf-keep fraction PER SOURCE. Stratified so the scarce,
    #    lower-confidence register data (capture/synth) isn't preferentially deleted by a
    #    global threshold that favors high-confidence corpus prose — register coverage is
    #    what the research says matters most for a small student.
    by_src: dict[str, list] = {}
    for o in deduped:
        by_src.setdefault(o.get("src", "?"), []).append(o)
    final = []; drop_conf = 0
    for src, group in by_src.items():
        group.sort(key=lambda r: -r.get("teacher_conf", 0))
        nk = max(1, int(len(group) * args.conf_keep))
        if args.corpus_cap and src == "corpus":      # rebalance: trim abundant prose
            nk = min(nk, args.corpus_cap)
        final += group[:nk]; drop_conf += len(group) - nk

    gold_prompts = {o["prompt"] for o in final}
    rng = random.Random(args.seed)

    # 4) replay anchor: raw general continuations, prompts disjoint from the distilled set
    replay = []
    if args.replay_frac > 0 and args.replay_src.exists():
        pool = []
        for l in args.replay_src.read_text(encoding="utf-8").splitlines():
            l = l.strip()
            if not l:
                continue
            o = json.loads(l)
            if o.get("prompt") and o.get("completion") and o["prompt"] not in gold_prompts:
                pool.append({"prompt": o["prompt"], "completion": o["completion"], "src": "replay"})
        rng.shuffle(pool)
        replay = pool[: int(len(final) * args.replay_frac)]

    mix = final + replay
    rng.shuffle(mix)

    # 5) emit mlx "text" format (the exact inference string), 90/10 train/valid
    args.out_mlx.mkdir(parents=True, exist_ok=True)
    rows = [json.dumps({"text": (o["prompt"] + o["completion"]).strip()}, ensure_ascii=False) + "\n"
            for o in mix if (o["prompt"] + o["completion"]).strip()]
    rng.shuffle(rows)
    k = max(1, len(rows) // 10)
    (args.out_mlx / "valid.jsonl").write_text("".join(rows[:k]), encoding="utf-8")
    (args.out_mlx / "train.jsonl").write_text("".join(rows[k:]), encoding="utf-8")

    src_mix = Counter(o.get("src", "?") for o in final)
    print(f"gold in: {n0}")
    print(f"  dropped: len={drop_len} empty={drop_empty} repetition={drop_rep} dedup={drop_dup} conf={drop_conf}")
    print(f"  kept distilled: {len(final)}  (src mix: {dict(src_mix)})")
    print(f"  + replay anchor: {len(replay)} ({args.replay_frac:.0%})")
    print(f"  -> mlx text: train {len(rows)-k}  valid {k}  @ {args.out_mlx}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
