#!/usr/bin/env python3
"""Fetch bounded, categorized public-corpus text for typer-1's cold-start SFT.

This is the "general examples for general users" seed: before typer-1 has tailored to
anyone, it learns to do inline completion well across the registers Typer sees — chat,
docs/email, web prose, and code. Output lands in --out as one .jsonl per category, in the
shape build_dataset.py --corpus already consumes ({"text": ..., "category": ...}); it then
slices each line into prefix -> 5-7-word continuation SFT positives.

License posture (central base training = public data only, matching docs/autocomplete-model.md):
all sources here are Apache-2.0 / CC-BY-SA / ODC-By — no Pile/Books3/Reddit/CC-BY-NC.

Memory-safe by construction: every source is *streamed* (datasets streaming=True), so we
never hold a whole corpus in RAM, and each is capped (--max-per-source) so a fresh machine
pulls a bounded amount. Each source is isolated in try/except — a gated or unavailable one
is skipped with a warning, never aborting the others.

  uv run fetch_corpus.py --out corpus --max-per-source 8000
  uv run fetch_corpus.py --sources chat,docs            # subset

Then: BASE=HuggingFaceTB/SmolLM2-360M CORPUS=corpus ./train.sh all
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Each source: (key, category, hf repo, config, split, field-spec). field-spec is a list of
# dataset columns to try, in order, for the natural-text body; the first non-empty wins. For
# instruction sets we pull the human-written response, which is the prose worth completing.
SOURCES = [
    # chat / IM register — OpenAssistant conversations (Apache-2.0), English only.
    ("chat",  "chat",    "OpenAssistant/oasst1",             None, "train",      ["text"]),
    # docs / instruction-response prose — Dolly (CC-BY-SA).
    ("dolly", "docs",    "databricks/databricks-dolly-15k",  None, "train",      ["response", "context", "instruction"]),
    # web / docs prose — FineWeb-Edu sample (ODC-By). The big one; streaming + cap keep it small.
    ("web",   "browser", "HuggingFaceFW/fineweb-edu",        "sample-10BT", "train", ["text"]),
    # code register — permissive CodeParrot validation slice (the user types lots of code).
    ("code",  "code",    "codeparrot/codeparrot-clean-valid", None, "train",     ["content", "code"]),
]

# Per-source language guards / minimal cleaning, keyed by source key.
def _ok(key: str, ex: dict, text: str) -> bool:
    if len(text) < 40:                       # too short to slice into prefix+continuation
        return False
    if key == "chat" and ex.get("lang") not in (None, "en"):
        return False
    return True


def fetch_one(key, category, repo, config, split, fields, cap, out_dir) -> int:
    from datasets import load_dataset
    ds = load_dataset(repo, config, split=split, streaming=True)
    path = out_dir / f"{category}.jsonl"
    n = 0
    # Append mode: two sources sharing a category accumulate into one file.
    with path.open("a", encoding="utf-8") as f:
        for ex in ds:
            if n >= cap:
                break
            text = ""
            for col in fields:
                v = ex.get(col)
                if isinstance(v, str) and v.strip():
                    text = v.strip()
                    break
            if not text or not _ok(key, ex, text):
                continue
            f.write(json.dumps({"text": text, "category": category}, ensure_ascii=False) + "\n")
            n += 1
    return n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path(__file__).parent / "corpus")
    ap.add_argument("--max-per-source", type=int, default=8000,
                    help="cap docs pulled per source (keeps downloads + SFT bounded)")
    ap.add_argument("--sources", default="",
                    help="comma-separated source keys to include (default: all). "
                         f"available: {','.join(s[0] for s in SOURCES)}")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    want = {s.strip() for s in args.sources.split(",") if s.strip()}
    total = 0
    for key, category, repo, config, split, fields in SOURCES:
        if want and key not in want:
            continue
        try:
            print(f"==> {key:6} [{category}] {repo}{(' '+config) if config else ''} (≤{args.max_per_source})", flush=True)
            got = fetch_one(key, category, repo, config, split, fields, args.max_per_source, args.out)
            print(f"    {got} docs -> {args.out / (category + '.jsonl')}", flush=True)
            total += got
        except Exception as e:  # gated / offline / schema drift — skip, don't abort the rest
            print(f"    !! skipped {key} ({repo}): {type(e).__name__}: {e}", file=sys.stderr, flush=True)

    print(f"\nTotal {total} docs across {args.out}/. Next: CORPUS={args.out} ./train.sh data")
    if total == 0:
        print("No corpus fetched (all sources skipped). Check network / `uv sync` / HF access.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
