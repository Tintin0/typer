#!/usr/bin/env python3
"""Verify a candidate base model satisfies Typer's hard tokenizer + BOS contract.

The app is not tokenizer-agnostic. Three things in scripts/llama_server.cpp depend on
the tokenizer, and they break SILENTLY if a base model violates them — so this must run
before adopting (or after fusing) any model:

  1. WORD-BOUNDARY: a generated token with a LEADING SPACE means "new word"; no leading
     space means "continue the current word". So " word" must tokenize to a start token
     that carries the space (byte-level BPE "Ġword" or SentencePiece "▁word"), and it
     must differ from how "word" tokenizes. The +0.5 lexicon boost on the first token of
     " word" relies on this too.
  2. BOS: prompt_complete() currently prepends a literal "<bos>". That is correct ONLY
     for the Gemma tokenizer. For SmolLM2 (<|endoftext|>) / Qwen (no BOS) the literal
     string tokenizes to junk bytes. This prints the model's real BOS convention so you
     can fix prompt_complete()/tokenize(add_special) for the new model.
  3. SPECIAL TOKENS: the -inf ban list (init_biases) is Gemma-specific. This prints the
     model's actual special/added tokens so the ban can be rebuilt by id, not by string.

Exits non-zero if the word-boundary contract fails (a hard disqualifier).
Needs `transformers` (uv add transformers). Run:
  uv run training/tokenizer_preflight.py --model HuggingFaceTB/SmolLM2-360M
"""
from __future__ import annotations

import argparse
import sys

PROBE_WORDS = ["word", "dinner", "tomorrow", "the", "application", "really"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="HF repo id or local path of the BASE model")
    args = ap.parse_args()

    try:
        from transformers import AutoTokenizer
    except ImportError:
        print("transformers not installed. `uv add transformers` (or `uv pip install transformers`).", file=sys.stderr)
        return 2

    tok = AutoTokenizer.from_pretrained(args.model)
    print(f"model: {args.model}")
    print(f"vocab size: {tok.vocab_size}  (smaller = less embedding RAM + faster prefill)")
    print(f"bos_token: {tok.bos_token!r}   eos_token: {tok.eos_token!r}")
    print(f"adds bos by default: {getattr(tok, 'add_bos_token', 'n/a')}")

    # --- BOS convention guidance for prompt_complete() ---
    enc_special = tok("hello world", add_special_tokens=True)["input_ids"]
    enc_plain = tok("hello world", add_special_tokens=False)["input_ids"]
    leads_with_bos = bool(enc_special) and (len(enc_special) > len(enc_plain)) and enc_special[: len(enc_special) - len(enc_plain)] != []
    print("\n[BOS] llama_server.cpp prompt_complete() must match this model:")
    if tok.bos_token and leads_with_bos:
        print(f"      this model DOES use a BOS ({tok.bos_token!r}). Prepend the REAL bos token via")
        print("      add_special=true in tokenize(), not a hardcoded literal string.")
    else:
        print("      this model does NOT prepend a <bos>. REMOVE the literal \"<bos>\" prefix from")
        print("      prompt_complete() (a literal '<bos>' tokenizes to junk bytes here).")

    # --- word-boundary contract ---
    print("\n[WORD-BOUNDARY] ' word' must be a single space-prefixed start token, distinct from 'word':")
    ok = True
    for w in PROBE_WORDS:
        sp = tok.tokenize(" " + w)
        no = tok.tokenize(w)
        first = sp[0] if sp else ""
        carries_space = bool(first) and (first[0] in ("Ġ", "▁") or first.startswith(" "))  # Ġ or ▁
        distinct = sp != no
        single = len(sp) == 1
        flag = "ok" if (carries_space and distinct) else "FAIL"
        if not (carries_space and distinct):
            ok = False
        print(f"  ' {w}'.tokenize -> {sp}   (space-prefixed={carries_space}, distinct={distinct}, single-token={single})  [{flag}]")

    # --- special tokens to rebuild the ban list ---
    specials = list(dict.fromkeys(tok.all_special_tokens + [str(t) for t in getattr(tok, "additional_special_tokens", [])]))
    print(f"\n[SPECIALS] rebuild init_biases() to ban these by id (not by string): {specials}")

    print()
    if ok:
        print("PASS: word-boundary contract holds. Safe base for Typer (after the BOS fix above).")
        return 0
    print("FAIL: word-boundary contract violated — this base would break spacing, mid-word")
    print("      suppression, and the lexicon boost. Do NOT use it. Pick a byte-level-BPE")
    print("      (SmolLM2 / Qwen) or SentencePiece-metaspace (Gemma) base.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
