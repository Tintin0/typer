#!/usr/bin/env python3
"""Generate synthetic preference data for cold-start RL (Phase 0.5) — no users, no teacher.

The adversarial review's rule: do NOT run real preference learning until there are
hundreds of genuine accepts. Before that (and on a fresh, logging-off install) the model
still needs to learn what a BAD inline completion looks like. We manufacture that here,
deterministically, from the SFT positives (corpus + the user's own style.txt slices).

For each good (prompt -> continuation) we emit negatives that mirror the exact failure
modes the C++ server already tries to repair (llama_server.cpp: remove_echo,
limit_words, looks_bad_completion, the special-token ban, and the mid-word/no-leading-
space suppression). Training the model to DISprefer these bakes the runtime contracts
into the weights, so the confidence gate has real signal from day one:

  echo          repeat the tail of the context (the remove_echo target)
  overlong      run well past the 5-7 word / sentence-end budget
  special       inject a banned "<|...|>" / channel/turn fragment
  midword       drop the leading space so it continues mid-word (suppressed)
  generic       swap in high-frequency filler ("a lot of the things that")
  repeat        repeat the first word 4+ times (the repetition detector)
  truncated     cut the final word mid-way

Outputs (under --out): kto_synth.jsonl {prompt, completion, label, weight, kind} and
dpo_synth.jsonl {prompt, chosen, rejected, kind}. Feed these in Phase 0.5 (and mix a
small fraction into later real KTO as hard negatives). Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

GENERIC_FILLERS = [
    " a lot of the things that", " the thing that you", " one of the most",
    " in order to make sure", " at the end of the", " a number of different",
]
SPECIAL_FRAGMENTS = ["<|", " <|channel>", "|>", " <turn|>", " <|endoftext|>"]


def last_line(prompt: str) -> str:
    """The live text the model is continuing (the block after the last blank line)."""
    return prompt.split("\n\n")[-1]


def words(s: str) -> list[str]:
    return s.split()


def make_negatives(prompt: str, good: str, rng: random.Random) -> list[tuple[str, str]]:
    """Return [(kind, bad_completion)] for one positive."""
    good = good.rstrip()
    gw = words(good)
    ctx_tail = words(last_line(prompt))
    out: list[tuple[str, str]] = []

    # echo: regurgitate the last few words of the context
    if len(ctx_tail) >= 2:
        out.append(("echo", " " + " ".join(ctx_tail[-min(5, len(ctx_tail)):])))

    # overlong: continue well past the budget with filler
    out.append(("overlong", (good + " " + GENERIC_FILLERS[rng.randrange(len(GENERIC_FILLERS))]
                             + " and then continued on for a while longer than it should have").strip()))
    if not out[-1][1].startswith(" "):
        out[-1] = ("overlong", " " + out[-1][1])

    # special: inject a banned fragment
    frag = SPECIAL_FRAGMENTS[rng.randrange(len(SPECIAL_FRAGMENTS))]
    out.append(("special", (good + frag) if gw else (frag + " text")))

    # midword: drop the leading space + first char so it starts mid-word
    if good.lstrip() and len(good.lstrip()) > 2:
        out.append(("midword", good.lstrip()[2:]))

    # generic: replace entirely with high-frequency filler
    out.append(("generic", GENERIC_FILLERS[rng.randrange(len(GENERIC_FILLERS))]))

    # repeat: repeat the first word several times
    if gw:
        w = gw[0].strip()
        if w:
            out.append(("repeat", " " + " ".join([w] * 5)))

    # truncated: cut the final word in half
    if gw and len(gw[-1]) > 3:
        cut = gw[:-1] + [gw[-1][: len(gw[-1]) // 2]]
        out.append(("truncated", " " + " ".join(cut)))

    # Keep only negatives that actually differ from the positive.
    return [(k, b) for (k, b) in out if b.strip() and b.strip() != good.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sft", type=Path, default=Path(__file__).parent / "data" / "sft.jsonl",
                    help="positives to corrupt {prompt, completion}. Default: %(default)s")
    ap.add_argument("--out", type=Path, default=Path(__file__).parent / "data")
    ap.add_argument("--per-positive", type=int, default=3, help="negatives sampled per positive")
    ap.add_argument("--limit", type=int, default=0, help="cap positives (0 = all)")
    ap.add_argument("--seed", type=int, default=20260617)
    args = ap.parse_args()

    if not args.sft.exists():
        print(f"no positives at {args.sft} — run build_dataset.py (with --corpus) first.")
        return 2
    rng = random.Random(args.seed)
    args.out.mkdir(parents=True, exist_ok=True)

    pos = []
    for line in args.sft.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        if o.get("prompt") and o.get("completion"):
            pos.append(o)
        if args.limit and len(pos) >= args.limit:
            break

    kto, dpo = [], []
    kinds: dict[str, int] = {}
    for p in pos:
        prompt, good = p["prompt"], p["completion"]
        # The positive itself, strongly weighted.
        kto.append({"prompt": prompt, "completion": good, "label": True, "weight": 2.0, "kind": "good"})
        negs = make_negatives(prompt, good, rng)
        rng.shuffle(negs)
        for kind, bad in negs[: args.per_positive]:
            kto.append({"prompt": prompt, "completion": bad, "label": False, "weight": 1.0, "kind": kind})
            dpo.append({"prompt": prompt, "chosen": good, "rejected": bad, "kind": kind})
            kinds[kind] = kinds.get(kind, 0) + 1

    def dump(name, rows):
        path = args.out / name
        with path.open("w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        return path

    p_kto = dump("kto_synth.jsonl", kto)
    p_dpo = dump("dpo_synth.jsonl", dpo)
    print(f"positives:        {len(pos)}")
    print(f"KTO synth rows:   {len(kto):>7}  -> {p_kto}")
    print(f"DPO synth pairs:  {len(dpo):>7}  -> {p_dpo}")
    print(f"negative kinds:   {kinds}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
