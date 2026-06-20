#!/usr/bin/env python3
"""Multiply collected human golds into a large training set via the Anthropic Batch API (50% off).

Reads the human-accepted golds from collect_human_data.py and asks a teacher for many close
variations of each — same person, same voice, different day — turning a few hundred real golds
into hundreds of thousands of realistic, human-grounded pairs without slop. Async, idempotent,
resumable like distill_teacher_batch.py: run once to submit, again to collect (or --wait).

  ANTHROPIC_API_KEY=sk-... uv run training/expand_human_data.py --per-gold 150 --wait

Variations append to data/human_grounded.jsonl ({prompt, completion, src:"human-var", base}),
the same file collect_human_data.py writes — ready to fold into build_distill_sft.py for FT.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

from collect_human_data import VARIATION_SYS, norm_completion, parse_json_array, append


def custom_id(prompt: str, completion: str) -> str:
    return "g_" + hashlib.sha1((prompt + "\x00" + completion).encode("utf-8")).hexdigest()


def context_of(prompt: str) -> tuple[str, str]:
    """Recover (app, context) from a "Writing app: {app}\\n\\n{context}" prompt."""
    if prompt.startswith("Writing app:"):
        head, _, body = prompt.partition("\n\n")
        return head[len("Writing app:"):].strip() or "a text field", body
    return "a text field", prompt


def load_golds(path: Path) -> list[dict]:
    seen, out = set(), []
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = (o.get("prompt"), o.get("completion"))
        if o.get("prompt") and o.get("completion") and key not in seen:
            seen.add(key)
            out.append(o)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--golds", type=Path, default=Path("data/human_golds.jsonl"))
    ap.add_argument("--out", type=Path, default=Path("data/human_grounded.jsonl"))
    ap.add_argument("--model", default="claude-haiku-4-5")
    ap.add_argument("--per-gold", type=int, default=150, help="variations requested per human gold")
    ap.add_argument("--wait", action="store_true", help="block until the batch ends, then collect")
    ap.add_argument("--poll", type=int, default=30)
    args = ap.parse_args()

    state_path = args.out.with_suffix(args.out.suffix + ".expand.json")
    import anthropic
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY not set", file=sys.stderr); return 2
    cli = anthropic.Anthropic()

    # COLLECT: a batch is already in flight.
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        while True:
            b = cli.messages.batches.retrieve(state["batch_id"])
            print(f"batch {state['batch_id']}: {b.processing_status}", file=sys.stderr)
            if b.processing_status == "ended":
                break
            if not args.wait:
                print("still processing — re-run to collect (or pass --wait).", file=sys.stderr); return 0
            time.sleep(args.poll)
        gmap = state["map"]
        kept = 0
        for entry in cli.messages.batches.results(state["batch_id"]):
            g = gmap.get(entry.custom_id)
            if g is None or entry.result.type != "succeeded":
                continue
            text = "".join(getattr(x, "text", "") for x in entry.result.message.content
                           if getattr(x, "type", "") == "text")
            _, context = context_of(g["prompt"])
            base = g["completion"].strip().lower()
            seen = {base}
            for s in parse_json_array(text):
                v = norm_completion(context, str(s))
                if v and v.strip().lower() not in seen:
                    seen.add(v.strip().lower())
                    append(args.out, {"prompt": g["prompt"], "completion": v,
                                      "register": g.get("register", "other"), "src": "human-var",
                                      "base": g["completion"]})
                    kept += 1
        state_path.unlink()
        print(f"expanded into {kept} variation pairs -> {args.out}", file=sys.stderr)
        return 0

    # SUBMIT: build one request per gold.
    golds = load_golds(args.golds)
    if not golds:
        print(f"no golds in {args.golds} — collect some first with collect_human_data.py", file=sys.stderr)
        return 0
    requests, gmap = [], {}
    max_tokens = min(8000, args.per_gold * 16 + 200)
    for g in golds:
        app, context = context_of(g["prompt"])
        cid = custom_id(g["prompt"], g["completion"])
        gmap[cid] = g
        requests.append({
            "custom_id": cid,
            "params": {
                "model": args.model, "max_tokens": max_tokens, "temperature": 1.0,
                "system": VARIATION_SYS,
                "messages": [{"role": "user", "content":
                              f"[typing in {app}]\nContext: {context!r}\nTheir continuation: {g['completion'].strip()!r}\n\n"
                              f"Write {args.per_gold} variations as a JSON array of strings."}],
            },
        })
    batch = cli.messages.batches.create(requests=requests)
    state_path.write_text(json.dumps({"batch_id": batch.id, "model": args.model, "map": gmap}),
                          encoding="utf-8")
    print(f"submitted batch {batch.id}: {len(requests)} golds × ~{args.per_gold} variations", file=sys.stderr)

    if args.wait:
        while True:
            b = cli.messages.batches.retrieve(batch.id)
            print(f"  {b.processing_status}…", file=sys.stderr)
            if b.processing_status == "ended":
                break
            time.sleep(args.poll)
        # Re-enter the collect path by recursing once.
        return main()
    print("re-run the same command to poll + collect.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
