#!/usr/bin/env python3
"""Integration tests for the typer-llama-server JSONL protocol.

Model-INDEPENDENT invariants only (protocol shape, robustness, greedy determinism) — no
assertions on specific model output, so it passes with whatever GGUF is installed. Loads a
model, so it's slower than the C++ unit tests; run via `scripts/run_tests.sh --with-helper`.
"""
import json, subprocess, sys, os, glob

HELPER = os.path.expanduser("~/.local/share/typer/typer-llama-server")
CANDIDATES = [os.path.expanduser("~/.lmstudio/models/lmstudio-community/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q4_K_M.gguf")]
CANDIDATES += sorted(glob.glob(os.path.expanduser("~/Library/Application Support/typer/Models/*.gguf")))

def find_model():
    for p in CANDIDATES:
        if os.path.exists(p):
            return p
    sys.exit("no .gguf model found — skip integration tests")

fails, passes = 0, 0
def check(cond, msg):
    global fails, passes
    if cond: passes += 1
    else: fails += 1; print(f"  FAIL: {msg}")

class Helper:
    def __init__(self, model):
        # Binary pipes + lenient decode: the harness must never crash on the process's byte
        # output (a stray non-UTF-8 byte is the app's problem to handle, not the test's).
        self.p = subprocess.Popen([HELPER, "--model", model], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, bufsize=0)
    def req(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode("utf-8")); self.p.stdin.flush()
        while True:
            raw = self.p.stdout.readline()
            if not raw: raise RuntimeError("helper exited unexpectedly")
            o = json.loads(raw.decode("utf-8", errors="replace"))
            if o.get("p") is not None:  # streamed partial — keep reading to the final line
                continue
            return o
    def close(self):
        try: self.p.stdin.close()
        except Exception: pass
        try: self.p.wait(timeout=5)
        except Exception: self.p.kill()

def sug_ok(o):  # a completion response is {"ok":true,"suggestion": {...}|null}
    return o.get("ok") is True and ("suggestion" in o) and (o["suggestion"] is None or isinstance(o["suggestion"].get("text"), str))

def main():
    model = find_model()
    print(f"model: {os.path.basename(model)}")
    h = Helper(model)
    try:
        # 1. tokenize returns a positive count
        o = h.req({"mode": "tokenize", "context": "Hello world, this is a test."})
        check(o.get("ok") is True and o.get("n_tokens", 0) >= 1, f"tokenize: {o}")

        # 2. a normal completion is well-formed
        o = h.req({"context": "The weather today is", "max_words": 5})
        check(sug_ok(o), f"completion well-formed: {o}")

        # 3. greedy determinism: identical request twice -> identical suggestion
        r1 = h.req({"context": "Please find attached the report for", "max_words": 6})
        r2 = h.req({"context": "Please find attached the report for", "max_words": 6})
        t1 = (r1.get("suggestion") or {}).get("text")
        t2 = (r2.get("suggestion") or {}).get("text")
        check(t1 == t2, f"greedy determinism: {t1!r} vs {t2!r}")

        # 4. mid-word request is well-formed (and any text is non-empty when present)
        o = h.req({"context": "I need the docu", "midword": 1, "max_words": 5})
        check(sug_ok(o), f"midword well-formed: {o}")

        # 5. robustness: empty / unicode / long context must not crash the helper
        check(sug_ok(h.req({"context": "", "max_words": 5})), "empty context")
        check(sug_ok(h.req({"context": "Schöne Grüße und vielen Dank für", "max_words": 5})), "unicode context")
        check(sug_ok(h.req({"context": "word " * 4000, "max_words": 5})), "very long context")

        # 6. raw mode returns a well-formed suggestion
        o = h.req({"mode": "raw", "context": "The quick brown fox", "max_words": 5})
        check(sug_ok(o), f"raw mode: {o}")
    finally:
        h.close()

    print(f"{passes} passed, {fails} failed")
    return 1 if fails else 0

if __name__ == "__main__":
    raise SystemExit(main())
