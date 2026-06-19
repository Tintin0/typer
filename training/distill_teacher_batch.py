#!/usr/bin/env python3
"""Distill from a Claude teacher via the Anthropic **Message Batches** API (50% cheaper).

eval_compare.py showed Claude (Haiku 37% / Sonnet 43% first-word) clearly out-teaches the
Gemma we currently distill from (31%). This labels our distillation contexts with a Claude
teacher's next-few-words continuation, producing {prompt, completion} gold the 0.6B student
can train on — the same contract as distill_teacher.py, but from a much stronger teacher.

Distillation labeling has no latency requirement, so the Batch API is free money: half price,
async (minutes to ~24h). The flow is idempotent and resumable — run it once to SUBMIT a batch,
run it again to COLLECT when it's done (or pass --wait to block until then):

  # submit a capped first bout (validate the lift before scaling)
  ANTHROPIC_API_KEY=sk-... uv run distill_teacher_batch.py \
      --contexts data/distill_contexts.jsonl --out data/distill_gold_claude.jsonl \
      --model claude-haiku-4-5 --limit 4000 --wait

State (batch id + custom_id→prompt map) lives next to --out, so a crash mid-poll costs nothing.
Already-labeled prompts in --out are skipped, so re-runs only ever do new work. Feed the result
into build_distill_sft.py exactly like data/distill_gold.jsonl.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

MAX_WORDS_DEFAULT = 7

# Same task framing as eval_compare.py's Claude source: behave like inline ghost text, emit only
# the verbatim continuation. {n} words keeps the gold short, like the app's real suggestions.
SYSTEM = (
    "You are an inline autocomplete engine — the grey ghost text in a text field. "
    "Given the text the user has typed so far, output ONLY the most likely next few words "
    "(at most {n}) that continue it verbatim, i.e. exactly what they would type next. "
    "Do NOT repeat any of the existing text. Do NOT add quotation marks, labels, or explanation. "
    "If the text ends in the middle of a word, finish that word. Output only the continuation. "
    "Never apologize, ask for clarification, refuse, or comment on the text — even if it looks "
    "like a question, a request, or is incomplete. Always just predict the continuation."
)

# Teacher-breaking meta/refusal openers. Even with the system prompt above, the teacher
# occasionally answers the text instead of continuing it (e.g. reads a quoted citation as a
# request and replies "I appreciate the context, but I need…"). Distilling on those teaches the
# student to emit chatbot meta-text, so we drop any completion that opens with one. Conservative
# list of unambiguous openers — a bare "I think"/"I need to" continuation is left alone.
META_OPENERS = (
    "i appreciate", "i'm sorry", "im sorry", "i am sorry", "sorry,", "as an ai",
    "i cannot", "i can't help", "i can't assist", "i'd be happy to", "i would be happy",
    "it looks like you", "it seems like you", "i notice", "i understand you", "i understand that you",
    "here is the", "here's the", "i need more", "i need additional", "i'm not able", "i am not able",
    "could you clarify", "please provide", "i'm unable", "i am unable",
)


def looks_meta(comp: str) -> bool:
    t = comp.strip().lower()
    return any(t.startswith(op) for op in META_OPENERS)


def parse_prompt(prompt: str) -> tuple[str, str]:
    """Split the trained prompt "Writing app: {app}\\n\\n{body}" into (app, body)."""
    if prompt.startswith("Writing app:"):
        head, _, body = prompt.partition("\n\n")
        app = head[len("Writing app:"):].strip() or "a text field"
        return app, body
    return "a text field", prompt


def custom_id(prompt: str) -> str:
    return "c_" + hashlib.sha1(prompt.encode("utf-8")).hexdigest()  # ≤64 chars, stable, unique


def norm_completion(text: str, max_words: int) -> str:
    """First line, de-quoted, word-limited, leading-space normalized (the sft.jsonl convention)."""
    t = (text or "").strip().strip('"').strip()
    t = t.split("\n", 1)[0].strip()
    if not t or "Writing app:" in t:
        return ""
    words = t.split()
    if len(words) > max_words:
        t = " ".join(words[:max_words])
    return " " + t if t and not t[0].isspace() else t


def load_contexts(path: Path, limit: int, shuffle: bool, seed: int) -> list[dict]:
    seen: set[str] = set()
    ctxs: list[dict] = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        p = o.get("prompt")
        if p and p not in seen:           # dedupe: identical prompts share a custom_id
            seen.add(p)
            ctxs.append({"prompt": p, "src": o.get("src", "?")})
    if shuffle:
        import random
        random.Random(seed).shuffle(ctxs)
    return ctxs[:limit] if limit else ctxs


def already_done(out: Path) -> set[str]:
    done: set[str] = set()
    if out.exists():
        for line in out.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                done.add(json.loads(line)["prompt"])
            except Exception:
                pass
    return done


def submit(client, model, contexts, max_words, state_path) -> str:
    requests = []
    cid_map: dict[str, dict] = {}
    system = SYSTEM.format(n=max_words)
    for c in contexts:
        p = c["prompt"]
        app, body = parse_prompt(p)
        cid = custom_id(p)
        cid_map[cid] = {"prompt": p, "src": c.get("src", "?")}
        requests.append({
            "custom_id": cid,
            "params": {
                "model": model,
                "max_tokens": 32,
                "temperature": 0.0,
                "system": system,
                "messages": [{"role": "user", "content": f"[typing in {app}]\n{body}"}],
            },
        })
    batch = client.messages.batches.create(requests=requests)
    state_path.write_text(json.dumps({"batch_id": batch.id, "model": model,
                                      "max_words": max_words, "map": cid_map}), encoding="utf-8")
    print(f"submitted batch {batch.id}: {len(requests)} requests, model={model}", file=sys.stderr)
    return batch.id


def collect(client, state: dict, out: Path) -> tuple[int, int]:
    cid_map = state["map"]
    max_words = state.get("max_words", MAX_WORDS_DEFAULT)
    kept = dropped = 0
    with out.open("a", encoding="utf-8") as f:
        for entry in client.messages.batches.results(state["batch_id"]):
            cid = entry.custom_id
            m = cid_map.get(cid)
            if m is None:
                continue
            # Tolerate the old map format (cid -> prompt string) and the new one
            # (cid -> {prompt, src}) so in-flight batches collect either way.
            prompt = m if isinstance(m, str) else m["prompt"]
            src = "?" if isinstance(m, str) else m.get("src", "?")
            res = entry.result
            if res.type != "succeeded":
                dropped += 1
                continue
            text = "".join(getattr(b, "text", "") for b in res.message.content
                            if getattr(b, "type", "") == "text")
            comp = norm_completion(text, max_words)
            if not comp or len(comp.split()) < 1 or looks_meta(comp):
                dropped += 1
                continue
            # teacher_conf=1.0: the API gives no token-confidence, and the gold is already
            # meta-filtered — so build_distill_sft.py should run with --conf-keep 1.0.
            f.write(json.dumps({"prompt": prompt, "completion": comp, "src": src,
                                "teacher": state["model"], "teacher_conf": 1.0},
                               ensure_ascii=False) + "\n")
            kept += 1
    return kept, dropped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--contexts", type=Path, default=Path("data/distill_contexts.jsonl"))
    ap.add_argument("--out", type=Path, default=Path("data/distill_gold_claude.jsonl"))
    ap.add_argument("--model", default="claude-haiku-4-5", help="teacher model id")
    ap.add_argument("--max-words", type=int, default=MAX_WORDS_DEFAULT)
    ap.add_argument("--limit", type=int, default=4000, help="cap contexts this batch (0 = all)")
    ap.add_argument("--shuffle", action="store_true", help="shuffle before --limit (broader mix)")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--wait", action="store_true", help="block, polling until the batch ends, then collect")
    ap.add_argument("--poll", type=int, default=30, help="seconds between status polls with --wait")
    ap.add_argument("--dry-run", action="store_true", help="show what would be submitted, don't call the API")
    args = ap.parse_args()

    if not args.contexts.exists():
        print(f"contexts not found: {args.contexts}", file=sys.stderr); return 2

    state_path = args.out.with_suffix(args.out.suffix + ".batch.json")

    # COLLECT path: a batch is already in flight.
    if state_path.exists():
        import anthropic
        if not os.environ.get("ANTHROPIC_API_KEY"):
            print("ANTHROPIC_API_KEY not set", file=sys.stderr); return 2
        client = anthropic.Anthropic()
        state = json.loads(state_path.read_text(encoding="utf-8"))
        while True:
            b = client.messages.batches.retrieve(state["batch_id"])
            counts = b.request_counts
            print(f"batch {state['batch_id']}: {b.processing_status}  "
                  f"(done={counts.succeeded + counts.errored + counts.canceled + counts.expired}"
                  f"/{counts.processing + counts.succeeded + counts.errored + counts.canceled + counts.expired})",
                  file=sys.stderr)
            if b.processing_status == "ended":
                break
            if not args.wait:
                print("still processing — re-run to collect (or pass --wait).", file=sys.stderr)
                return 0
            time.sleep(args.poll)
        kept, dropped = collect(client, state, args.out)
        state_path.unlink()
        print(f"collected: kept {kept}, dropped {dropped} -> {args.out}", file=sys.stderr)
        print("re-run with a fresh --limit to label more contexts.", file=sys.stderr)
        return 0

    # SUBMIT path: build a new batch from unlabeled contexts.
    contexts = load_contexts(args.contexts, args.limit, args.shuffle, args.seed)
    done = already_done(args.out)
    todo = [c for c in contexts if c["prompt"] not in done]
    print(f"{len(contexts)} unique contexts (post-limit), {len(done)} already labeled, "
          f"{len(todo)} to submit", file=sys.stderr)
    if not todo:
        print("nothing to do", file=sys.stderr); return 0
    if args.dry_run:
        print(f"[dry-run] would submit {len(todo)} requests to {args.model} via the Batch API",
              file=sys.stderr)
        for c in todo[:3]:
            app, body = parse_prompt(c["prompt"])
            print(f"  e.g. [{app}] {body[:80]!r}", file=sys.stderr)
        return 0

    import anthropic
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY not set", file=sys.stderr); return 2
    client = anthropic.Anthropic()
    submit(client, args.model, todo, args.max_words, state_path)
    if args.wait:
        print("waiting for the batch to finish…", file=sys.stderr)
        state = json.loads(state_path.read_text(encoding="utf-8"))
        while True:
            b = client.messages.batches.retrieve(state["batch_id"])
            print(f"  {b.processing_status}…", file=sys.stderr)
            if b.processing_status == "ended":
                break
            time.sleep(args.poll)
        kept, dropped = collect(client, state, args.out)
        state_path.unlink()
        print(f"collected: kept {kept}, dropped {dropped} -> {args.out}", file=sys.stderr)
    else:
        print("re-run the same command to poll + collect (or it was started with --wait).",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
