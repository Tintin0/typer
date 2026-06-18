#!/usr/bin/env python3
"""Sequence-level knowledge distillation: label contexts with the teacher's in-app suggestion.

For each context we ask the SAME typer-llama-server the app uses (so the completion is exactly
the teacher's production behavior — its fixed sampler, word limit, gate), and write a
{prompt, completion} pair the student can train on. This transfers the teacher's continuation
quality into a smaller/faster student without needing logits (we only ever see text), which is
all GGUF/llama.cpp exposes.

Resumable by construction: results append to --out and already-labeled prompts are skipped on
restart, so a sleep / lid-close / Ctrl-C costs at most the in-flight request. One persistent
teacher process, one request at a time — same memory profile as eval.

  uv run distill_teacher.py --teacher <gemma.gguf> --contexts data/distill_contexts.jsonl \
      --out data/distill_gold.jsonl --max-words 7 --min-teacher-conf 0.15

Then build_dataset/prepare can fold data/distill_gold.jsonl into the SFT mix (with a replay
anchor) per the anti-forgetting recipe.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from eval import Server  # reuse the exact one-request-at-a-time protocol driver


def norm_completion(text: str) -> str:
    """Match the sft.jsonl convention: a single leading space, no trailing whitespace."""
    t = (text or "").rstrip()
    if not t:
        return ""
    if not t[0].isspace():
        t = " " + t
    return t


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--teacher", type=Path, required=True, help="teacher .gguf (e.g. Gemma)")
    ap.add_argument("--contexts", type=Path, required=True, help="jsonl with {prompt[, src]}")
    ap.add_argument("--out", type=Path, required=True, help="jsonl {prompt, completion, src, teacher_conf}")
    ap.add_argument("--server", type=Path, default=Path.home() / ".local/share/typer/typer-llama-server")
    ap.add_argument("--max-words", type=int, default=7)
    ap.add_argument("--min-teacher-conf", type=float, default=0.0,
                    help="drop teacher completions below this confidence (cleaner gold)")
    ap.add_argument("--min-words", type=int, default=2,
                    help="drop completions shorter than this (no-info type-throughs)")
    ap.add_argument("--limit", type=int, default=0, help="cap contexts processed (0 = all)")
    args = ap.parse_args()

    if not args.server.exists():
        print(f"server not found: {args.server}", file=sys.stderr); return 2
    if not args.teacher.exists():
        print(f"teacher not found: {args.teacher}", file=sys.stderr); return 2

    contexts = []
    for l in args.contexts.read_text(encoding="utf-8", errors="ignore").splitlines():
        l = l.strip()
        if not l:
            continue
        o = json.loads(l)
        if o.get("prompt"):
            contexts.append(o)
    if args.limit:
        contexts = contexts[: args.limit]

    # Resume: skip prompts already labeled in --out.
    done = set()
    if args.out.exists():
        for l in args.out.read_text(encoding="utf-8", errors="ignore").splitlines():
            l = l.strip()
            if not l:
                continue
            try:
                done.add(json.loads(l)["prompt"])
            except Exception:
                pass
    todo = [c for c in contexts if c["prompt"] not in done]
    print(f"{len(contexts)} contexts, {len(done)} already done, {len(todo)} to label", file=sys.stderr)
    if not todo:
        print("nothing to do", file=sys.stderr); return 0

    srv = Server(args.server, args.teacher)
    kept = dropped = 0
    t0 = time.monotonic()
    try:
        with args.out.open("a", encoding="utf-8") as f:
            for i, c in enumerate(todo, 1):
                text, conf, _lat, _ttfp = srv.request(c["prompt"], args.max_words)
                comp = norm_completion(text)
                nwords = len(comp.split())
                if not comp or nwords < args.min_words or conf < args.min_teacher_conf:
                    dropped += 1
                else:
                    f.write(json.dumps({"prompt": c["prompt"], "completion": comp,
                                        "src": c.get("src", "?"), "teacher_conf": round(float(conf), 4)},
                                       ensure_ascii=False) + "\n")
                    kept += 1
                if i % 200 == 0:
                    f.flush()
                    rate = i / max(1e-6, time.monotonic() - t0)
                    eta = (len(todo) - i) / max(1e-6, rate)
                    print(f"  {i}/{len(todo)}  kept={kept} dropped={dropped}  {rate:.1f}/s  eta {eta/60:.1f}m",
                          file=sys.stderr)
    finally:
        srv.close()
    print(f"done: kept {kept}, dropped {dropped} (conf<{args.min_teacher_conf} or <{args.min_words} words) -> {args.out}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
