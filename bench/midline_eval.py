#!/usr/bin/env python3
"""Repeatable mid-line completion eval for Typer's helper.

Mid-line = the caret has text AFTER it on the same line. For models without FIM tokens
(e.g. gemma-4) the helper keeps a short forward "bridge" fragment that fits before the
trailing text (see bridge_to_suffix in scripts/llama_server.cpp). This script drives that
path over a set of EN/DE cases and prints, per case, how the completion reads BETWEEN the
prefix and the suffix — so a regression (collision with / duplication of the trailing text)
is obvious. Rerun after any change to the completion path.

  python3 bench/midline_eval.py [model.gguf]
  GROUND=1 python3 bench/midline_eval.py         # prepend a persona block, as Typer's
                                                  # global_instructions grounding does
  MAXW=7 GROUND=1 PERSONA="..." python3 bench/midline_eval.py [model.gguf]

Env: MAXW (words per completion, default 7); GROUND (1 = prepend PERSONA); PERSONA
(override the placeholder persona used for grounding).
"""
import json, subprocess, sys, os, glob

HELPER = os.path.expanduser("~/.local/share/typer/typer-llama-server")
MODELS_DIR = os.path.expanduser("~/Library/Application Support/typer/Models")

def default_model():
    if len(sys.argv) > 1:
        return sys.argv[1]
    hits = sorted(glob.glob(os.path.join(MODELS_DIR, "*.gguf")))
    if not hits:
        sys.exit(f"no model given and no .gguf in {MODELS_DIR}")
    return hits[0]

MODEL = default_model()
MAXW = int(os.environ.get("MAXW", "7"))
GROUND = os.environ.get("GROUND", "0") == "1"
# Placeholder persona for grounded runs — NOT anyone's real data. Override with PERSONA=...
PERSONA = os.environ.get("PERSONA",
    "My name is Alex Doe. I write in English and German. I work in operations and often "
    "write emails and short reports. Keep sentences short, professional and readable.")

# (text before caret, text after caret). EN + DE, email/office flavour.
CASES = [
    ("Please find attached the", " for your review."),
    ("I will send you the", " by the end of the day."),
    ("Thank you for your", ". I will get back to you shortly."),
    ("Please review the attached", " and let me know your comments."),
    ("Können Sie mir bitte", " bis morgen zusenden?"),
    ("Vielen Dank für", ". Ich melde mich nächste Woche."),
    ("I have reviewed the document and", " before we proceed."),
    ("Bitte beachten Sie, dass", " nicht bindend ist."),
]

def ctx(prefix):
    if not GROUND:
        return prefix
    return f"Instructions: {PERSONA}\n\nWriting app: Mail\n\n{prefix}"

reqs = "".join(json.dumps({"context": ctx(p), "suffix": s, "max_words": MAXW}) + "\n" for p, s in CASES)
out = subprocess.run([HELPER, "--model", MODEL], input=reqs, capture_output=True, text=True).stdout
finals = [json.loads(l) for l in out.splitlines() if '"suggestion"' in l]

print(f"model: {os.path.basename(MODEL)}   MAXW={MAXW} GROUND={GROUND}\n")
for (p, s), r in zip(CASES, finals + [None] * len(CASES)):
    sug = (r or {}).get("suggestion")
    text = sug.get("text") if sug else None
    conf = sug.get("conf") if sug else None
    if not text:
        print(f"  [{p}]⎵(none)⎵[{s}]\n"); continue
    sentence = f"{p}{'' if text.startswith(' ') else ' '}{text}{s}"
    print(f"  [{p}]⎵{text}⎵[{s}]   (conf {conf})")
    print(f"  => {sentence.strip()}\n")
