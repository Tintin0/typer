#!/usr/bin/env python3
"""Build a realistic *typed-content* eval set — what people actually type, mid-utterance.

The old held-out set (sft.jsonl / heldout.jsonl) is corpus PROSE: literary passages,
license headers, Wikipedia. Autocomplete is judged on chat replies, emails, code, commit
messages, search queries and notes — short, mid-sentence, register-specific. Scoring TYPER
on prose flatters or punishes it for the wrong reasons. This script writes a set that looks
like the real input distribution, so eval_compare.py measures the thing we care about.

Two sources, blended:
  • curated   — hand-written, committed, reproducible examples across registers, each cut at
                a natural mid-utterance point with the literal next few words as gold.
  • sliced    — real public *non-prose* corpora already on disk (training/corpus/chat.jsonl,
                code.jsonl) cut mid-message. Excludes browser.jsonl/docs.jsonl (that's prose).

Each row: {context, app, completion, register, source}. `context` is the text typed so far
(no app prefix); eval_compare.py adds the app-label block the model was trained on, and hands
Claude teachers the bare context. `completion` is the gold next text, leading-space normalized
like sft.jsonl.

Stdlib only. Deterministic (seeded). Run:
  uv run training/build_typed_eval.py --out training/data/typed_eval.jsonl
"""
from __future__ import annotations

import argparse
import json
import random
import re
from pathlib import Path

# --- curated: realistic mid-utterance typing across the registers the app actually sees ----
# (context, app, gold-completion). Gold is the literal next words a person would type; kept
# short (the app suggests 3-7). Leading space is added on write, so don't include it here.
CURATED: list[tuple[str, str, str]] = [
    # chat / IM
    ("hey, are we still on for the meeting", "Slack", "tomorrow morning"),
    ("sorry for the late reply, i was", "Messages", "in a meeting all day"),
    ("can you send me the link to the", "Slack", "design doc when you get a chance"),
    ("yeah that works for me, let's", "Discord", "do it then"),
    ("i think we should probably just", "Slack", "ship it and see"),
    ("no worries, take your time. just let me", "Messages", "know when you're ready"),
    ("omg that's hilarious, i can't believe she", "WhatsApp", "actually said that"),
    ("running like 10 minutes late, be there", "Messages", "as soon as i can"),
    ("did you get a chance to look at the", "Slack", "PR i opened yesterday"),
    ("lol same, i've been meaning to do that", "Discord", "for ages"),
    ("thanks so much for your help with", "Slack", "this, really appreciate it"),
    ("are you free to hop on a quick call", "Slack", "this afternoon"),
    # email
    ("Hi Sarah,\n\nThanks for getting back to me so", "Mail", "quickly"),
    ("Following up on my previous email — have you", "Mail", "had a chance to review"),
    ("Please find attached the revised proposal for", "Mail", "your review"),
    ("I wanted to reach out to schedule a time to", "Mail", "discuss the project"),
    ("Apologies for the delay in responding. I've been", "Outlook", "out of office this week"),
    ("Let me know if you have any questions or", "Mail", "need anything else from me"),
    ("Looking forward to hearing from you and", "Mail", "thanks again for your time"),
    # code
    ("def calculate_total(items):\n    total = 0\n    for item in", "VS Code", "items:"),
    ("import numpy as np\nimport pandas as", "Cursor", "pd"),
    ("if user is None:\n        raise ValueError(", "VS Code", '"user not found")'),
    ("const handleClick = (e) => {\n    e.preventDefault", "VS Code", "()"),
    ("for (let i = 0; i <", "Cursor", "arr.length; i++) {"),
    ("    return res.status(404).json({ error:", "VS Code", '"not found" })'),
    ("public class UserController extends", "VS Code", "BaseController {"),
    ("SELECT name, email FROM users WHERE", "DataGrip", "active = true"),
    ("try:\n        response = requests.get(url,", "Cursor", "timeout=10)"),
    ("git checkout -b feature/add-", "Terminal", "user-auth"),
    # commit messages
    ("fix: prevent crash when", "Terminal", "config file is missing"),
    ("refactor: extract validation logic into", "Terminal", "a separate module"),
    ("docs: update README with", "Terminal", "installation instructions"),
    ("feat: add support for", "Terminal", "dark mode"),
    # search queries
    ("how to center a div in", "Chrome", "css"),
    ("best restaurants near", "Safari", "me open now"),
    ("python convert string to", "Chrome", "datetime"),
    ("what time is it in", "Arc", "tokyo"),
    ("weather forecast for", "Safari", "this weekend"),
    ("how do i reset my", "Chrome", "github password"),
    ("difference between let and", "Arc", "const in javascript"),
    # notes / docs / longer-form
    ("Action items from today's standup:\n- finish the", "Notes", "auth refactor"),
    ("Remember to pick up groceries on the way", "Notes", "home"),
    ("The main goal of this quarter is to", "Notion", "improve onboarding"),
    ("Meeting notes: we decided to postpone the", "Notes", "launch until next month"),
    ("TODO: investigate why the build is", "Obsidian", "failing on CI"),
    ("One thing I learned today is that you should always", "Notes", "back up your data"),
    # questions / instructions (typed prompts)
    ("Can you explain the difference between TCP and", "ChatGPT", "UDP"),
    ("Write a function that takes a list and returns the", "ChatGPT", "sum of all even numbers"),
    ("What are some good strategies for", "ChatGPT", "managing technical debt"),
    ("Summarize the key points from the", "ChatGPT", "attached document"),
]

CHAT_APPS = ["Slack", "Messages", "Discord", "WhatsApp", "Telegram"]
CODE_APPS = ["VS Code", "Cursor", "Zed", "Sublime Text"]
WORD_RE = re.compile(r"\S+")


def norm_completion(text: str) -> str:
    t = (text or "").rstrip()
    if not t:
        return ""
    return t if t[0].isspace() else " " + t


def slice_text(text: str, rng: random.Random, max_ctx_words: int, gold_words: int):
    """Cut a message mid-stream: (context, gold) or None if it can't be sliced sensibly."""
    words = WORD_RE.findall(text)
    if len(words) < 10:
        return None
    # Need room for a real prefix and a real gold continuation.
    lo = 5
    hi = len(words) - gold_words - 1
    if hi <= lo:
        return None
    cut = rng.randint(lo, hi)
    ctx_words = words[max(0, cut - max_ctx_words):cut]
    gold = words[cut:cut + gold_words]
    if not ctx_words or not gold:
        return None
    # Gold must carry actual content (not pure punctuation).
    if not any(any(c.isalnum() for c in w) for w in gold):
        return None
    return " ".join(ctx_words), " ".join(gold)


def load_corpus(path: Path, limit: int) -> list[str]:
    out: list[str] = []
    if not path.exists():
        return out
    with path.open(encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                t = json.loads(line).get("text", "")
            except json.JSONDecodeError:
                continue
            if t and len(t) > 40:
                out.append(t)
            if len(out) >= limit:
                break
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path("training/data/typed_eval.jsonl"))
    ap.add_argument("--corpus-dir", type=Path, default=Path("training/corpus"))
    ap.add_argument("--n-chat", type=int, default=80, help="sliced chat examples")
    ap.add_argument("--n-code", type=int, default=50, help="sliced code examples")
    ap.add_argument("--gold-words", type=int, default=5)
    ap.add_argument("--max-ctx-words", type=int, default=40)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    rows: list[dict] = []

    # curated
    for ctx, app, comp in CURATED:
        register = {
            "Mail": "email", "Outlook": "email",
            "VS Code": "code", "Cursor": "code", "DataGrip": "code", "Terminal": "shell",
            "Chrome": "search", "Safari": "search", "Arc": "search",
            "Notes": "notes", "Notion": "notes", "Obsidian": "notes",
            "ChatGPT": "prompt",
        }.get(app, "chat")
        rows.append({"context": ctx, "app": app, "completion": norm_completion(comp),
                     "register": register, "source": "curated"})

    # sliced chat (real typed questions/instructions/messages)
    chat = load_corpus(args.corpus_dir / "chat.jsonl", limit=4000)
    rng.shuffle(chat)
    n = 0
    for t in chat:
        # Take the first message/turn only; drop multi-paragraph dumps so it reads as one typed msg.
        t = t.split("\n\n")[0].strip()
        sl = slice_text(t, rng, args.max_ctx_words, args.gold_words)
        if not sl:
            continue
        ctx, gold = sl
        rows.append({"context": ctx, "app": rng.choice(CHAT_APPS), "completion": norm_completion(gold),
                     "register": "chat", "source": "sliced"})
        n += 1
        if n >= args.n_chat:
            break

    # sliced code (real typed code)
    code = load_corpus(args.corpus_dir / "code.jsonl", limit=4000)
    rng.shuffle(code)
    n = 0
    for t in code:
        sl = slice_text(t, rng, args.max_ctx_words, args.gold_words)
        if not sl:
            continue
        ctx, gold = sl
        rows.append({"context": ctx, "app": rng.choice(CODE_APPS), "completion": norm_completion(gold),
                     "register": "code", "source": "sliced"})
        n += 1
        if n >= args.n_code:
            break

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    by_reg: dict[str, int] = {}
    by_src: dict[str, int] = {}
    for r in rows:
        by_reg[r["register"]] = by_reg.get(r["register"], 0) + 1
        by_src[r["source"]] = by_src.get(r["source"], 0) + 1
    print(f"wrote {len(rows)} examples -> {args.out}")
    print("  by register:", ", ".join(f"{k}={v}" for k, v in sorted(by_reg.items())))
    print("  by source:  ", ", ".join(f"{k}={v}" for k, v in sorted(by_src.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
