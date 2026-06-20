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

from collect_human_data import norm_completion, parse_json_array, append

# Variation instructions tuned for the bulk training set: short, in-register, human, no slop.
# (collect_human_data.py keeps its own lighter prompt for the live preview; this is the one that
# shapes the data we actually train on.)
EXPAND_VARIATION_SYS = (
    "A real person typed a short continuation in their own voice while mid-sentence in an app. "
    "Write alternative continuations the SAME person might type on another day. Hard rules:\n"
    "- SHORT: about the same length as the original, never more than ~2 words longer. Inline "
    "autocomplete, not a sentence rewrite.\n"
    "- Same register, exactly: casual stays casual, lowercase stays lowercase, slang and "
    "abbreviations stay, no added punctuation or capitalization.\n"
    "- Sound like a person mid-thought, NOT an assistant. Never add pleasantries, hedges, or "
    "filler — no 'I'd be happy to', 'let me', 'sure', 'of course', 'feel free', 'happy to help', "
    "'great', and don't pad with 'just'/'actually'/'basically' unless the original had them.\n"
    "- Don't make it more formal, more correct, more complete, or more enthusiastic. Add no new "
    "information and no explanation.\n"
    "- Each item is ONLY the continuation text (what comes right after the context)."
)

# Assistant-y / marketing openers and phrases that mark a non-human variation.
SLOP_OPENERS = ("i'd be happy", "i would be happy", "let me ", "sure,", "sure!", "of course",
                "certainly", "absolutely", "here's ", "here is ", "no problem", "i can help",
                "i'll help", "i hope")
SLOP_ANYWHERE = ("as an ai", "happy to help", "feel free", "i hope this helps", "please note",
                 "let me know if", "don't hesitate")


def looks_human(text: str, base_words: int) -> bool:
    t = text.strip()
    if not t or not any(c.isalnum() for c in t):
        return False
    low = t.lower()
    if any(low.startswith(s) for s in SLOP_OPENERS) or any(s in low for s in SLOP_ANYWHERE):
        return False
    wc = len(t.split())
    # No unnecessary length: at most ~2 words past what the human actually wrote, hard cap 14.
    return wc <= max(base_words + 2, 5) and wc <= 14


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
        kept = dropped = 0
        for entry in cli.messages.batches.results(state["batch_id"]):
            g = gmap.get(entry.custom_id)
            if g is None or entry.result.type != "succeeded":
                continue
            text = "".join(getattr(x, "text", "") for x in entry.result.message.content
                           if getattr(x, "type", "") == "text")
            _, context = context_of(g["prompt"])
            base_comp = g["completion"].strip()
            base_words = len(base_comp.split())
            seen = {base_comp.lower()}                 # drop exact echoes of the human's own turn
            for s in parse_json_array(text):
                raw = str(s).strip().strip('"')
                if not looks_human(raw, base_words):   # slop / length filter
                    dropped += 1
                    continue
                if raw.lower() in seen:
                    continue
                seen.add(raw.lower())
                append(args.out, {"prompt": g["prompt"], "completion": norm_completion(context, raw),
                                  "register": g.get("register", "other"), "src": "human-var",
                                  "base": base_comp})
                kept += 1
        state_path.unlink()
        print(f"expanded into {kept} variation pairs (dropped {dropped} as slop/too-long) -> {args.out}",
              file=sys.stderr)
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
        base_words = len(g["completion"].split())
        requests.append({
            "custom_id": cid,
            "params": {
                "model": args.model, "max_tokens": max_tokens, "temperature": 1.0,
                "system": EXPAND_VARIATION_SYS,
                "messages": [{"role": "user", "content":
                              f"[typing in {app}]\nContext: {context!r}\nTheir continuation: {g['completion'].strip()!r}\n\n"
                              f"That continuation is {base_words} word(s). Write {args.per_gold} variations of it, "
                              f"each roughly {base_words} words (never more than {base_words + 2}). "
                              f"Return ONLY a JSON array of strings."}],
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
