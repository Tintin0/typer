#!/usr/bin/env python3
"""Objective completion-quality benchmark for Typer.

Drives the built helper over a curated gold set (bench/quality_gold.jsonl: context -> a
plausible continuation) and reports FIRST-WORD ACCURACY and PREFIX-OVERLAP — so any change
(persona, screenshot-OCR filtering, model, gate) becomes measurable instead of vibes. Runs
each case with the persona grounding OFF and ON so the persona's effect is visible.

  python3 bench/quality_eval.py [model.gguf]
  PERSONA="…" python3 bench/quality_eval.py         # override the grounding persona

Absolute numbers are a proxy (one gold continuation per context); the DELTA between runs is
the signal. Loads a model, so it's slower than the unit tests.
"""
import json, subprocess, os, glob, re, sys

HELPER = os.path.expanduser("~/.local/share/typer/typer-llama-server")
GOLD = os.path.join(os.path.dirname(__file__), "quality_gold.jsonl")
CANDS = [os.path.expanduser("~/.lmstudio/models/lmstudio-community/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q4_K_M.gguf")]
CANDS += sorted(glob.glob(os.path.expanduser("~/Library/Application Support/typer/Models/*.gguf")))
MODEL = sys.argv[1] if len(sys.argv) > 1 else next((p for p in CANDS if os.path.exists(p)), None)
if not MODEL: sys.exit("no model found")

# Placeholder persona (NOT personal data) — override with PERSONA=... to measure your own.
PERSONA = os.environ.get("PERSONA",
    "I write professional emails and legal documents in English and German. "
    "Friendly, concise, clear.")

def grounded(prefix):
    return f"Instructions: {PERSONA}\n\nWriting app: Mail\n\n{prefix}"

class Helper:
    def __init__(self, model):
        self.p = subprocess.Popen([HELPER, "--model", model], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, bufsize=0)
    def complete(self, context):
        self.p.stdin.write((json.dumps({"context": context, "max_words": 7}) + "\n").encode()); self.p.stdin.flush()
        while True:
            raw = self.p.stdout.readline()
            if not raw: raise RuntimeError("helper exited")
            o = json.loads(raw.decode("utf-8", errors="replace"))
            if o.get("p") is not None: continue
            s = o.get("suggestion")
            return (s or {}).get("text") or ""
    def close(self):
        try: self.p.stdin.close(); self.p.wait(timeout=5)
        except Exception: self.p.kill()

def norm(s): return re.sub(r"^[^0-9A-Za-zÀ-ÿ]+|[^0-9A-Za-zÀ-ÿ]+$", "", s).lower()
def first(s):
    parts = s.split()
    return norm(parts[0]) if parts else ""
def lcp(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y: break
        n += 1
    return n

def run(cases, ground):
    h = Helper(MODEL)
    fw_hit = 0.0; ov_sum = 0.0
    rows = []
    try:
        for c in cases:
            ctx = grounded(c["context"]) if ground else c["context"]
            pred = h.complete(ctx)
            fw = 1.0 if first(pred) == first(c["expected"]) else 0.0
            exp_n = norm(c["expected"]); pred_n = norm(pred.strip())
            ov = lcp(pred_n, exp_n) / max(1, len(exp_n))
            fw_hit += fw; ov_sum += ov
            rows.append((c, pred, fw, ov))
    finally:
        h.close()
    return fw_hit / len(cases), ov_sum / len(cases), rows

def main():
    cases = [json.loads(l) for l in open(GOLD, encoding="utf-8") if l.strip()]
    print(f"model: {os.path.basename(MODEL)}   cases: {len(cases)}\n")
    results = {}
    for ground in (False, True):
        fw, ov, rows = run(cases, ground)
        results[ground] = (fw, ov)
        tag = "persona ON " if ground else "persona OFF"
        for lang in ("en", "de"):
            sub = [r for r in rows if r[0].get("lang") == lang]
            if sub:
                lfw = sum(r[2] for r in sub) / len(sub)
                print(f"  [{tag}] {lang}: first-word {lfw*100:4.0f}%  ({len(sub)} cases)")
        print(f"  [{tag}] ALL: first-word {fw*100:4.0f}%   prefix-overlap {ov*100:4.0f}%\n")
    d = (results[True][0] - results[False][0]) * 100
    print(f"persona effect on first-word accuracy: {d:+.0f} points")

if __name__ == "__main__":
    raise SystemExit(main())
