#!/usr/bin/env python3
"""Mine REAL human golds from the local Typer capture, privacy-cleaned, never leaving the Mac unscreened.

`~/Library/Application Support/typer/training.jsonl` records, per shown suggestion, the context you
typed and how you responded. The rows you ACCEPTED — Tab, backtick, or typed-through — are genuine
human continuations: the highest-fidelity data there is, because it's literally you. This extracts
them as golds in the collect_human_data.py format.

PRIVACY: capture already screens secrets at write time, but this adds a hard second pass — any row
whose context or continuation matches an email, URL, IP, phone, long digit run, file path, @handle,
or key-like token is DROPPED entirely (not redacted). Run with --review to eyeball a sample before
anything is used. Nothing is sent anywhere by this script; it only reads local capture and writes a
local golds file you can inspect.

  uv run training/mine_capture.py --review
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

PRIVATE = [
    re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),                 # email
    re.compile(r"https?://\S+|\bwww\.\S+"),                  # url
    re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"),              # ip
    re.compile(r"\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b"),        # phone
    re.compile(r"\b\d{5,}\b"),                               # long digit run (ids, cards, codes)
    re.compile(r"(?:^|\s)[~/][\w./-]{3,}"),                  # file path
    re.compile(r"(?:^|\s)@\w{2,}"),                          # @handle / mention
    re.compile(r"\b[A-Za-z0-9_-]{24,}\b"),                   # key/token-like long string
]


def looks_private(s: str) -> bool:
    return any(p.search(s) for p in PRIVATE)


def norm_completion(context: str, text: str) -> str:
    t = (text or "").strip()
    if not t:
        return ""
    if context and not context[-1].isspace() and not t[0].isspace():
        t = " " + t
    return t


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--capture", type=Path,
                    default=Path.home() / "Library/Application Support/typer/training.jsonl")
    ap.add_argument("--out", type=Path, default=Path("data/capture_golds.jsonl"))
    ap.add_argument("--max-ctx-chars", type=int, default=200, help="trim context to its tail")
    ap.add_argument("--review", action="store_true", help="print a sample + stats, write nothing")
    args = ap.parse_args()

    if not args.capture.exists():
        print(f"no capture at {args.capture}"); return 0

    kept, dropped_private, dropped_other = [], 0, 0
    for line in args.capture.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = r.get("accept_kind")
        wa = r.get("words_accepted") or 0
        if not (r.get("accepted") and wa > 0 and kind in {"tab", "backtick", "typethrough"}):
            continue
        ctx = (r.get("context") or "").rstrip()
        # The accepted continuation = the first `words_accepted` words of the shown suggestion.
        sug = (r.get("suggestion") or "").strip()
        gold = " ".join(sug.split()[:wa]).strip()
        if not ctx or not gold or not any(c.isalnum() for c in gold):
            dropped_other += 1
            continue
        if looks_private(ctx) or looks_private(gold):
            dropped_private += 1
            continue
        if len(ctx) > args.max_ctx_chars:
            ctx = ctx[-args.max_ctx_chars:]
        app = r.get("app_category", "other") or "other"
        kept.append({"prompt": f"Writing app: {app}\n\n{ctx}",
                     "completion": norm_completion(ctx, gold),
                     "app": app, "register": app, "source": f"capture:{kind}"})

    print(f"accepted rows kept: {len(kept)}  ·  dropped {dropped_private} (private) + {dropped_other} (empty)")
    if args.review:
        print("\nsample (privacy-cleaned) — context tail -> your continuation:")
        for g in kept[:12]:
            ctx = g["prompt"].split("\n\n", 1)[-1]
            print(f"  [{g['register']}] …{ctx[-44:]!r} -> {g['completion']!r}")
        print("\n(--review: nothing written. re-run without --review to save.)")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as f:
        for g in kept:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")
    print(f"wrote {len(kept)} capture golds -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
