#!/usr/bin/env python3
"""Compare completion *sources* on the realistic typed-content eval set — the diagnostic eval.

The single-model eval.py answers "is this GGUF good enough to promote." This answers two
different questions:

  1. Is TYPER's poor performance the MODEL or the HARNESS? We score the same weights twice —
     once through the full TYPER harness (tuned sampler, lexicon bias, streaming word-shaping,
     echo removal, quality gate) and once RAW (greedy, none of that). The harness-vs-raw delta
     says whether the harness earns its keep or is actively hurting us.

  2. Is there a better TEACHER to distill from? We score candidate teachers — the Gemma we ship,
     and Claude Haiku / Sonnet via the API — on the same set, ranked by how well their next-few-
     words match what a person actually typed. The top teacher is the one worth distilling.

Every source is scored identically against the same gold (training/data/typed_eval.jsonl from
build_typed_eval.py): first-word accuracy, type-through length (matched leading words), and a
"useful" rate (would it have saved at least one word). For the harness we also report the gate's
behavior — what it shows and whether what it shows is any good.

Local GGUF sources drive the real typer-llama-server (harness or raw mode). Claude sources use
the Anthropic API and need ANTHROPIC_API_KEY (and `anthropic` installed: `uv add anthropic`).

  uv run training/eval_compare.py \
      --data training/data/typed_eval.jsonl \
      --harness ~/Library/Application\\ Support/typer/Models/typer-1-distill.gguf \
      --teacher gemma:~/Library/Application\\ Support/typer/Models/gemma-4-E2B-i1-Q4_K_M.gguf \
      --claude claude-haiku-4-5 --claude claude-sonnet-4-6 \
      --out training/data/eval_compare_report.json
"""
from __future__ import annotations

import argparse
import json
import os
import string
import sys
import time
from pathlib import Path

from eval import Server, pct  # reuse the exact one-request-at-a-time protocol driver

PUNCT = string.punctuation


def words_norm(s: str) -> list[str]:
    """Lowercase, drop surrounding punctuation per word — fair across chat and code."""
    out = []
    for w in (s or "").split():
        w = w.strip(PUNCT).lower()
        if w:
            out.append(w)
    return out


def score(pred: str, gold: str) -> dict:
    p, g = words_norm(pred), words_norm(gold)
    matched = 0
    for a, b in zip(p, g):
        if a == b:
            matched += 1
        else:
            break
    first = bool(p) and bool(g) and p[0] == g[0]
    return {
        "first_word": 1.0 if first else 0.0,
        "matched": float(matched),
        "matched_ratio": matched / len(g) if g else 0.0,
        "useful": 1.0 if matched >= 1 else 0.0,
        "gold_words": len(g),
    }


# ---- sources ----------------------------------------------------------------------------

def model_context(ex: dict) -> str:
    """The model-facing prompt: the app-label block the model was trained on + typed text."""
    return f"Writing app: {ex['app']}\n\n{ex['context']}"


class LocalSource:
    """A GGUF driven through typer-llama-server, in harness or raw mode."""

    def __init__(self, name: str, label: str, server: Path, model: Path, mode: str | None,
                 max_words: int, min_conf: float):
        self.name = name
        self.label = label              # "harness" | "raw" | "teacher"
        self.mode = mode                # None = full harness, "raw" = greedy baseline
        self.max_words = max_words
        self.min_conf = min_conf
        self.srv = Server(server, model)

    def run(self, ex: dict):
        text, conf, latency, _ttfp = self.srv.request(model_context(ex), self.max_words, mode=self.mode)
        # The gate only exists in the real harness; raw/teacher (greedy) have no gate, so leave
        # `shown` unset for them rather than reporting a meaningless column.
        shown = (bool(text.strip()) and conf >= self.min_conf) if self.label == "harness" else None
        return {"text": text, "conf": conf, "latency": latency, "shown": shown}

    def close(self):
        self.srv.close()


CLAUDE_SYSTEM = (
    "You are an inline autocomplete engine — the grey ghost text in a text field. "
    "Given the text the user has typed so far, output ONLY the most likely next few words "
    "(at most {n}) that continue it verbatim, i.e. exactly what they would type next. "
    "Do NOT repeat any of the existing text. Do NOT add quotation marks, labels, or explanation. "
    "If the text ends in the middle of a word, finish that word. Output only the continuation."
)


class ClaudeSource:
    """A Claude model as a candidate teacher, via the Anthropic API (temperature 0)."""

    def __init__(self, model_id: str, max_words: int):
        try:
            import anthropic
        except ImportError:
            raise SystemExit("anthropic not installed. Run: (cd training && uv add anthropic)")
        if not os.environ.get("ANTHROPIC_API_KEY"):
            raise SystemExit("ANTHROPIC_API_KEY not set — needed for --claude sources.")
        self.name = model_id
        self.label = "teacher"
        self.max_words = max_words
        self.client = anthropic.Anthropic()
        self.system = CLAUDE_SYSTEM.format(n=max_words)

    def run(self, ex: dict):
        t0 = time.monotonic()
        # A short register/app hint helps it pick the right voice (chat vs code) without echoing.
        user = f"[typing in {ex['app']}]\n{ex['context']}"
        try:
            msg = self.client.messages.create(
                model=self.name, max_tokens=32, temperature=0.0,
                system=self.system,
                messages=[{"role": "user", "content": user}],
            )
            text = "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")
        except Exception as e:                       # surface the model that failed, keep going
            print(f"  ! {self.name}: {e}", file=sys.stderr)
            text = ""
        text = text.strip().strip('"').strip()
        text = text.split("\n", 1)[0]
        return {"text": text, "conf": None, "latency": (time.monotonic() - t0) * 1000, "shown": None}

    def close(self):
        pass


# ---- run + report -----------------------------------------------------------------------

def aggregate(rows: list[dict]) -> dict:
    n = len(rows)
    if n == 0:
        return {}
    fw = sum(r["s"]["first_word"] for r in rows) / n
    matched = sum(r["s"]["matched"] for r in rows) / n
    useful = sum(r["s"]["useful"] for r in rows) / n
    lat = [r["o"]["latency"] for r in rows if r["o"]["latency"]]
    out = {
        "n": n,
        "first_word": round(fw, 4),
        "matched_avg": round(matched, 3),
        "useful_rate": round(useful, 4),
        "latency_p50": round(pct(lat, 50), 1) if lat else None,
    }
    # Gate behavior (harness only): how much it shows, and whether what it shows is useful.
    if rows[0]["o"].get("shown") is not None:
        shown_rows = [r for r in rows if r["o"]["shown"]]
        useful_rows = [r for r in rows if r["s"]["useful"]]
        out["shown_rate"] = round(len(shown_rows) / n, 4)
        out["shown_precision"] = round(
            sum(r["s"]["useful"] for r in shown_rows) / len(shown_rows), 4) if shown_rows else 0.0
        # Useful suggestions the gate threw away (gate too strict).
        out["useful_suppressed"] = round(
            sum(0.0 if r["o"]["shown"] else 1.0 for r in useful_rows) / len(useful_rows), 4
        ) if useful_rows else 0.0
    return out


def by_register(rows: list[dict]) -> dict:
    regs: dict[str, list[dict]] = {}
    for r in rows:
        regs.setdefault(r["ex"]["register"], []).append(r)
    return {k: round(sum(x["s"]["first_word"] for x in v) / len(v), 3) for k, v in sorted(regs.items())}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=Path("training/data/typed_eval.jsonl"))
    ap.add_argument("--server", type=Path, default=Path.home() / ".local/share/typer/typer-llama-server")
    ap.add_argument("--harness", type=Path, help="GGUF to run through the full TYPER harness")
    ap.add_argument("--raw", type=Path, help="GGUF to run RAW (greedy baseline); default = --harness")
    ap.add_argument("--teacher", action="append", default=[], metavar="name:path",
                    help="local GGUF teacher to score (raw greedy), repeatable")
    ap.add_argument("--claude", action="append", default=[], metavar="MODEL_ID",
                    help="Claude teacher via Anthropic API, repeatable (needs ANTHROPIC_API_KEY)")
    ap.add_argument("--max-words", type=int, default=7)
    ap.add_argument("--min-confidence", type=float, default=0.22)
    ap.add_argument("--limit", type=int, default=0, help="cap examples (0 = all)")
    ap.add_argument("--out", type=Path, default=None, help="write the full report JSON here")
    args = ap.parse_args()

    rows_in = []
    for line in args.data.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if line:
            rows_in.append(json.loads(line))
    if args.limit:
        rows_in = rows_in[: args.limit]
    if not rows_in:
        print(f"no examples in {args.data}", file=sys.stderr)
        return 2

    # Build the source list in report order.
    sources: list = []
    raw_path = args.raw or args.harness
    if args.harness:
        sources.append(LocalSource("TYPER harness", "harness", args.server, args.harness, None,
                                   args.max_words, args.min_confidence))
    if raw_path:
        sources.append(LocalSource("raw model", "raw", args.server, raw_path, "raw",
                                   args.max_words, args.min_confidence))
    for spec in args.teacher:
        name, _, path = spec.partition(":")
        p = Path(os.path.expanduser(path))
        if not p.exists():
            print(f"  ! teacher {name}: not found at {p}, skipping", file=sys.stderr)
            continue
        sources.append(LocalSource(f"teacher:{name}", "teacher", args.server, p, "raw",
                                   args.max_words, args.min_confidence))
    for mid in args.claude:
        sources.append(ClaudeSource(mid, args.max_words))

    if not sources:
        print("no sources — pass at least --harness / --raw / --teacher / --claude", file=sys.stderr)
        return 2

    report: dict = {"data": str(args.data), "n": len(rows_in), "max_words": args.max_words,
                    "min_confidence": args.min_confidence, "sources": {}}
    for src in sources:
        print(f"==> {src.name}  ({len(rows_in)} examples)", file=sys.stderr)
        scored = []
        try:
            for i, ex in enumerate(rows_in, 1):
                out = src.run(ex)
                scored.append({"ex": ex, "o": out, "s": score(out["text"], ex["completion"])})
                if i % 40 == 0:
                    print(f"  …{i}/{len(rows_in)}", file=sys.stderr)
        finally:
            src.close()
        report["sources"][src.name] = {
            "label": src.label,
            "overall": aggregate(scored),
            "by_register": by_register(scored),
        }

    print_report(report)
    if args.out:
        args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nfull report -> {args.out}", file=sys.stderr)
    return 0


def print_report(report: dict) -> None:
    srcs = report["sources"]
    print("\n" + "=" * 78)
    print(f"TYPED-CONTENT EVAL  ·  {report['n']} examples  ·  max_words={report['max_words']}")
    print("=" * 78)
    hdr = f"{'source':<22}{'first':>7}{'match':>7}{'useful':>8}{'shown':>7}{'sh.good':>8}{'p50ms':>8}"
    print(hdr)
    print("-" * len(hdr))
    for name, d in srcs.items():
        o = d["overall"]
        def g(k, w, pctsign=False):
            v = o.get(k)
            if v is None:
                return f"{'—':>{w}}"
            return f"{v*100:>{w-1}.0f}%" if pctsign else f"{v:>{w}.1f}"
        print(f"{name:<22}"
              f"{o['first_word']*100:>6.0f}%"
              f"{o['matched_avg']:>7.2f}"
              f"{o['useful_rate']*100:>7.0f}%"
              f"{g('shown_rate',7,True)}"
              f"{g('shown_precision',8,True)}"
              f"{(str(int(o['latency_p50']))+'ms') if o.get('latency_p50') else '—':>8}")

    # Diagnostic 1: harness vs raw on the same weights.
    har = next((d for n, d in srcs.items() if d["label"] == "harness"), None)
    raw = next((d for n, d in srcs.items() if d["label"] == "raw"), None)
    if har and raw:
        ho, ro = har["overall"], raw["overall"]
        dfw = (ho["first_word"] - ro["first_word"]) * 100
        dm = ho["matched_avg"] - ro["matched_avg"]
        print("\nHARNESS vs RAW (same weights):")
        print(f"  first-word:  harness {ho['first_word']*100:.0f}%  vs raw {ro['first_word']*100:.0f}%"
              f"   Δ {dfw:+.0f} pts")
        print(f"  matched:     harness {ho['matched_avg']:.2f}  vs raw {ro['matched_avg']:.2f}"
              f"   Δ {dm:+.2f}")
        if "useful_suppressed" in ho:
            print(f"  gate:        shows {ho['shown_rate']*100:.0f}% of all, "
                  f"{ho['shown_precision']*100:.0f}% of shown are useful, "
                  f"but suppresses {ho['useful_suppressed']*100:.0f}% of genuinely useful ones")
        verdict = ("the harness HELPS" if dfw > 1 else
                   "the harness HURTS — its shaping/sampling/gate is costing accuracy" if dfw < -1 else
                   "harness and raw are ~even — the harness isn't adding much")
        print(f"  → {verdict}.")

    # Diagnostic 2: teacher ranking.
    teachers = [(n, d["overall"]) for n, d in srcs.items() if d["label"] == "teacher"]
    if teachers:
        teachers.sort(key=lambda kv: kv[1]["first_word"], reverse=True)
        print("\nTEACHER RANKING (best next-word match on real typed content):")
        for n, o in teachers:
            print(f"  {n:<24} first-word {o['first_word']*100:>3.0f}%   "
                  f"matched {o['matched_avg']:.2f}   useful {o['useful_rate']*100:.0f}%")
        print(f"  → best teacher to distill from: {teachers[0][0]}")

    # Per-register first-word, all sources.
    print("\nFIRST-WORD ACCURACY BY REGISTER:")
    regs = sorted({r for d in srcs.values() for r in d["by_register"]})
    print(f"{'source':<22}" + "".join(f"{r[:7]:>9}" for r in regs))
    for name, d in srcs.items():
        print(f"{name:<22}" + "".join(
            f"{d['by_register'].get(r, 0)*100:>8.0f}%" for r in regs))


if __name__ == "__main__":
    raise SystemExit(main())
