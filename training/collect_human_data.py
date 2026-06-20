#!/usr/bin/env python3
"""Interactively collect REAL human writing, then scale it with a teacher — without slop.

The problem this solves: AI-written continuations don't match how a specific person actually
types, so distilling on them caps quality. This grounds the data in YOUR writing. For each
realistic mid-typing scenario it asks "how would you write this?" — offering a few quick
candidate continuations (pick one) or letting you type your own. Your accepted turn is the
gold. A teacher (Haiku) then writes a handful of close variations on the spot so you can see
the multiplication; the heavy multiply-by-hundreds happens offline + cheaply with
`expand_human_data.py` (Batch API) once you've collected a few hundred golds.

  ANTHROPIC_API_KEY=sk-... uv run training/collect_human_data.py

Controls per scenario:  1/2/3 pick a candidate · type your own + Enter · :s skip · :q quit
Golds append to data/human_golds.jsonl (the seed for expand_human_data.py); the gold + its
inline variations also append to data/human_grounded.jsonl (ready-to-train pairs).
Resumable — just re-run; everything appends.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def client():
    try:
        import anthropic
    except ImportError:
        raise SystemExit("anthropic not installed. Run: (cd training && uv add anthropic)")
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit("ANTHROPIC_API_KEY not set.")
    return anthropic.Anthropic()


def ask(cli, model: str, system: str, user: str, max_tokens: int = 512) -> str:
    msg = cli.messages.create(model=model, max_tokens=max_tokens, temperature=1.0,
                              system=system, messages=[{"role": "user", "content": user}])
    return "".join(b.text for b in msg.content if getattr(b, "type", "") == "text").strip()


def parse_json_array(text: str) -> list:
    """Tolerant: pull the first [...] block and json-load it."""
    a, b = text.find("["), text.rfind("]")
    if a < 0 or b < 0 or b <= a:
        return []
    try:
        out = json.loads(text[a:b + 1])
        return out if isinstance(out, list) else []
    except json.JSONDecodeError:
        return []


def norm_completion(context: str, text: str) -> str:
    """Leading-space normalize like sft.jsonl: a single leading space unless the context already
    ends in whitespace; never trailing whitespace."""
    t = (text or "").strip().strip('"').strip()
    if not t:
        return ""
    if context and not context[-1].isspace() and not t[0].isspace():
        t = " " + t
    return t


SCENARIO_SYS = (
    "You invent realistic everyday typing scenarios. Each is a person partway through typing a "
    "real message in a real app, cut off mid-thought so there's a natural next-few-words "
    "continuation. Vary widely: chat/DM, email, code editor, terminal, notes, search, comments. "
    "Vary tone, formality, length, and who they're writing to. Keep contexts short and ordinary "
    "— the kind of thing a normal person types, not polished prose."
)
CANDIDATE_SYS = (
    "You are an inline autocomplete. Given the text someone has typed so far, output a few SHORT, "
    "natural next-few-words continuations (at most ~7 words each), each a genuinely DIFFERENT "
    "plausible way the SAME person might continue — varied phrasing, not paraphrases. No quotes, "
    "no labels, no trailing punctuation-only."
)
VARIATION_SYS = (
    "A real person typed a continuation in their own voice. Write variations the SAME person might "
    "plausibly type on a different day: keep their register, informality, length, and word choices "
    "— vary wording naturally, do NOT make it more formal, more correct, or more 'AI'. No new "
    "information, no rephrasing into something they wouldn't say. Each variation is just the "
    "continuation text (what comes after the context), nothing else."
)


def gen_scenarios(cli, model, n) -> list[dict]:
    txt = ask(cli, model, SCENARIO_SYS,
              f"Generate {n} scenarios as a JSON array. Each item: "
              f'{{"app": "<app name>", "register": "chat|email|code|shell|notes|search|other", '
              f'"context": "<the exact partial text typed so far, cut mid-sentence>"}}. '
              f"Return ONLY the JSON array.", max_tokens=1500)
    out = []
    for o in parse_json_array(txt):
        if isinstance(o, dict) and o.get("context"):
            out.append({"app": o.get("app", "Notes"), "register": o.get("register", "other"),
                        "context": str(o["context"])})
    return out


def gen_candidates(cli, model, app, context, k) -> list[str]:
    txt = ask(cli, model, CANDIDATE_SYS,
              f"[typing in {app}]\nText so far: {context!r}\n\n"
              f"Give {k} different continuations as a JSON array of strings.", max_tokens=300)
    return [str(s).strip().strip('"') for s in parse_json_array(txt) if str(s).strip()][:k]


def gen_variations(cli, model, app, context, gold, n) -> list[str]:
    txt = ask(cli, model, VARIATION_SYS,
              f"[typing in {app}]\nContext: {context!r}\nTheir continuation: {gold!r}\n\n"
              f"Write {n} variations as a JSON array of strings.", max_tokens=800)
    seen, out = {gold.strip().lower()}, []
    for s in parse_json_array(txt):
        v = str(s).strip().strip('"')
        if v and v.lower() not in seen:
            seen.add(v.lower()); out.append(v)
    return out[:n]


def append(path: Path, row: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default="claude-haiku-4-5")
    ap.add_argument("--golds", type=Path, default=Path("data/human_golds.jsonl"))
    ap.add_argument("--out", type=Path, default=Path("data/human_grounded.jsonl"))
    ap.add_argument("--candidates", type=int, default=3, help="A/B/C options shown per scenario")
    ap.add_argument("--inline-variations", type=int, default=5,
                    help="variations generated on the spot per accepted turn (the big multiply is "
                         "expand_human_data.py)")
    ap.add_argument("--refill", type=int, default=12, help="scenarios generated per API call")
    args = ap.parse_args()

    cli = client()
    print("Collecting human-grounded writing. 1/2/3 = pick · type your own + Enter · :s skip · :q quit\n")

    queue: list[dict] = []
    golds = pairs = 0
    n_seen = 0
    try:
        while True:
            if not queue:
                print("  …thinking up scenarios…", file=sys.stderr)
                queue = gen_scenarios(cli, args.model, args.refill)
                if not queue:
                    print("couldn't generate scenarios (API?). try again.", file=sys.stderr); break
            sc = queue.pop(0)
            n_seen += 1
            app, context = sc["app"], sc["context"]
            cands = gen_candidates(cli, args.model, app, context, args.candidates)

            print(f"\n─ #{n_seen}  [{sc['register']} · {app}] " + "─" * 18)
            print(f'  "{context}"')
            for i, c in enumerate(cands, 1):
                print(f"    {i}) {c}")
            try:
                raw = input("how would you write it? ").strip()
            except EOFError:
                break
            if raw == ":q":
                break
            if raw == ":s" or raw == "":
                continue
            if raw in {str(i) for i in range(1, len(cands) + 1)}:
                gold_text, source = cands[int(raw) - 1], "candidate"
            else:
                gold_text, source = raw, "typed"

            comp = norm_completion(context, gold_text)
            if not comp:
                continue
            prompt = f"Writing app: {app}\n\n{context}"
            append(args.golds, {"prompt": prompt, "completion": comp, "app": app,
                                "register": sc["register"], "source": source})
            append(args.out, {"prompt": prompt, "completion": comp, "register": sc["register"], "src": "human"})
            golds += 1; pairs += 1

            # Inline preview of the multiplication so you can see the variety building.
            for v in gen_variations(cli, args.model, app, context, gold_text, args.inline_variations):
                append(args.out, {"prompt": prompt, "completion": norm_completion(context, v),
                                  "register": sc["register"], "src": "human-var", "base": comp})
                pairs += 1
            print(f"  ✓ saved · {golds} golds · {pairs} pairs so far  (run expand_human_data.py to multiply by hundreds)")
    except KeyboardInterrupt:
        pass

    print(f"\nDone. {golds} human golds -> {args.golds}\n      {pairs} total pairs -> {args.out}")
    print("Next: scale them up cheaply with  uv run training/expand_human_data.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
