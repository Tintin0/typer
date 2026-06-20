#!/usr/bin/env python3
"""llama.cpp TTFT/throughput bench for Typer's incremental-autocomplete workload.

THE product metric is TTFT (time-to-first-token): ghost text must land in ~100ms or
the user has typed past it. This harness measures TTFT (p50/p95), prefill tok/s, and
decode tok/s for a GGUF over the realistic prompts in training/data/typed_eval.jsonl,
and it exercises the levers that actually move TTFT — chiefly KV prefix reuse on the
incremental prompt, plus -fa / -ngl / n_ubatch / quantized KV cache.

WHY drive the existing helper instead of llama-bench/llama-cli
-------------------------------------------------------------
The HARD constraint is TTFT measured at the SAME boundary the product feels:
bytes-on-stdout of the first ghost-text token. `scripts/llama_server.cpp` already:
  * implements KV prefix reuse (prepare_prompt() / stable_tail()) — the #1 TTFT lever,
  * streams partials as `{"p":"...","conf":...}` (the first such line IS first-token),
  * applies the exact production shaping/clamps (max_tokens = clamp(max_words+7, 8, 18)).
`llama-bench` reports aggregate pp/tg tok/s, not per-request streamed TTFT, and isn't
even built in this repo (~/.cache/typer-build/llama.cpp has no build/bin). So we drive
the helper over its JSONL protocol — identical to training/eval.py's Server class and
to what LlamaClient.swift speaks — and time the first `{"p":...}` byte. That measures
TTFT at precisely the product boundary and, crucially, runs the real prefix-reuse path.

This is the llama.cpp side of a two-backend comparison. The results JSON is written in
a backend-neutral schema (see SCHEMA_VERSION / build_result()) so an MLX harness can
emit the SAME shape and the two be diffed cell-for-cell.

The lever knobs (-fa, -ngl, n_ubatch, KV cache-type-k/-v, n_ctx, n_threads) live in the
C++ binary, not on its CLI. This harness controls them the way the binary exposes them:
env vars where the binary reads them, and otherwise it RECORDS the configured cell into
the results JSON and verifies the binary's compiled defaults via `--check` stderr, so a
sweep is reproducible and self-documenting even though we don't recompile per cell. Knobs
that require a recompile are noted per-field as "compiled-in" so the operator knows to
rebuild scripts/build.sh with the variant before trusting that cell. See LEVER_NOTES.

Scenarios (never blend cold and warm):
  cold        — fresh helper process per request: model load + Metal graph + first prefill.
  warm-off    — one warm process, INDEPENDENT prompts (no shared prefix) so prepare_prompt's
                `common` stays ~0: the honest full-prefill cost after an app switch / big edit.
  warm-on     — one warm process, INCREMENTAL replay: each typed_eval `context` is replayed
                as a growing prefix (append a few tokens per step) so KV prefix reuse fires
                the way Typer actually hits it keystroke-to-keystroke.
  idle-resume — warm process, sleep > Metal residency keep-alive (default 180s), then one
                request: measures the residency-eviction TTFT spike GGML_METAL_RESIDENCY_*
                targets. Off by default (slow); enable with --idle-resume.

Prefix-reuse hit rate: the ground-truth counter lives inside prepare_prompt() and is NOT
yet emitted (see scripts/llama_server.cpp:412-432 — there is no stderr counter today).
Until that one-liner lands, this harness reports the EXPECTED hit rate it constructs:
for warm-on it tokenizes the growing prefixes itself and reports common/len per step, so
common/len > 0.8 is visible. The TODO to read the real counter is in read_reuse_counter().

DRY-VALIDATION ONLY: this script never downloads weights and `--help` / `--dry-run` do no
model work. A real run needs a built helper (scripts/build.sh) and a local GGUF.

Run:  uv run bench/llamacpp_bench.py --model "<gguf>" --scenario warm-on
The timed path is stdlib-only (matches training/eval.py); the OPTIONAL GGUF-metadata
read (to confirm a file's arch, e.g. that typer-1l really is 1.7B-class) uses the
in-repo gguf-py, whose deps are declared in the PEP 723 block below so `uv run`
auto-provisions them. If they're absent the read degrades gracefully and the bench
still runs. Results -> bench/results/.
"""
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pyyaml"]
# ///
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path

# --- repo-relative anchors (this file lives at <repo>/bench/) -----------------
REPO = Path(__file__).resolve().parent.parent
DEFAULT_SERVER = Path.home() / ".local" / "share" / "typer" / "typer-llama-server"
DEFAULT_DATA = REPO / "training" / "data" / "typed_eval.jsonl"
DEFAULT_MODELS_DIR = Path.home() / "Library" / "Application Support" / "typer" / "Models"
RESULTS_DIR = REPO / "bench" / "results"

# Bump when the results JSON shape changes; the MLX harness must match this string.
SCHEMA_VERSION = "typer-bench/1"

# The C++ binary clamps generated tokens to clamp(max_words + 7, 8, 18). Mirror that
# EXACTLY here so decode-token accounting and the MLX harness agree (see fairness_notes).
MAX_WORDS_DEFAULT = 7


def clamp_max_tokens(max_words: int) -> int:
    """Mirror llama_server.cpp:613 — int max_tokens = clamp(max_words + 7, 8, 18)."""
    return max(8, min(18, max_words + 7))


# Levers we can/can't influence from here, recorded into every result for provenance.
# "env"      -> set before launch, binary reads it (verified to exist in the binary/runtime).
# "compiled" -> baked into scripts/llama_server.cpp; changing the cell needs a rebuild.
LEVER_NOTES = {
    "GGML_METAL_RESIDENCY_KEEP_ALIVE_S": "env  (rank 2: set 3600 to avoid >180s idle eviction)",
    "n_ctx": "compiled (llama_server.cpp:225, currently 1536; rank 4 -> 1024)",
    "n_ubatch": "compiled (llama_server.cpp:251, currently 512; rank 8 -> 128)",
    "n_batch": "compiled (llama_server.cpp:250, currently 512)",
    "flash_attn": "compiled (llama_server.cpp:254, AUTO; rank 7 -> ENABLED)",
    "n_gpu_layers": "compiled (llama_server.cpp:242, 999 = full offload)",
    "kv_type_k": "compiled (default F16; rank 6 -> Q8_0, needs FA ENABLED)",
    "kv_type_v": "compiled (default F16; rank 6 -> Q8_0, needs FA ENABLED)",
    "n_threads": "compiled (llama_server.cpp:252, hw/2; rank 9 -> P-cores only)",
}


# =============================================================================
# helpers: percentiles, tokenization-ish, gguf metadata
# =============================================================================
def pct(values: list[float], p: float) -> float:
    """p50/p95 the same way training/eval.py does (nearest-rank on sorted)."""
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, int(round((p / 100) * (len(s) - 1))))
    return s[k]


def approx_tokens(text: str) -> int:
    """Cheap token estimate for the EXPECTED prefix-reuse accounting only.

    The ground-truth token counts come from the server (prompt_tokens it actually
    decoded), but those aren't exposed in the current JSONL schema, so for the
    reuse visualization we approximate ~4 chars/token. This is ONLY used to show
    common/len growth on the incremental stream; it never feeds the timed metrics.
    """
    return max(1, round(len(text) / 4))


def gguf_arch(model: Path) -> dict:
    """Read arch / param hints from GGUF metadata, to confirm what a file really is.

    The model_matrix warns typer-1l.gguf (1.2GB) is *likely* a 1.7B-class GGUF but must
    be CONFIRMED before being trusted as the 1.7B datapoint. Uses the in-repo gguf-py
    reader (no extra deps); returns {} if unavailable so dry-validation never fails.
    """
    info: dict = {}
    gguf_py = Path.home() / ".cache" / "typer-build" / "llama.cpp" / "gguf-py"
    if not model.exists() or not gguf_py.exists():
        return info
    try:
        sys.path.insert(0, str(gguf_py))
        from gguf import GGUFReader  # type: ignore

        r = GGUFReader(str(model))
        want = ("general.architecture", "general.name", "general.size_label",
                "general.file_type")
        for key in want:
            f = r.get_field(key)
            if f is None:
                continue
            try:
                info[key.split(".")[-1]] = f.contents()
            except Exception:
                pass
        # block_count is the layer count, a good arch fingerprint.
        for f in r.fields.values():
            if f.name.endswith("block_count"):
                try:
                    info["block_count"] = f.contents()
                except Exception:
                    pass
                break
    except Exception as e:
        info["_gguf_error"] = str(e)
    finally:
        if str(gguf_py) in sys.path:
            sys.path.remove(str(gguf_py))
    return info


# =============================================================================
# server driver
# =============================================================================
class Helper:
    """A typer-llama-server child driven one request at a time (like the app & eval.py).

    Timing boundary (THE product metric): t0 is the instant we finish writing the request;
    TTFT is the wall time to the first byte of the first `{"p":...}` partial on stdout —
    exactly when the first ghost-text token is available to render. The final
    `{"ok":true,...}` line bounds end-to-end suggestion latency.
    """

    def __init__(self, server: Path, model: Path, extra_env: dict | None = None):
        env = os.environ.copy()
        if extra_env:
            env.update({k: str(v) for k, v in extra_env.items()})
        # stderr is kept (not DEVNULL like eval.py) so we can scrape the prefix-reuse
        # counter once scripts/llama_server.cpp emits it (see read_reuse_counter()).
        self.proc = subprocess.Popen(
            [str(server), "--model-path", str(model)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=1, text=True, encoding="utf-8", errors="replace", env=env,
        )

    def request(self, context: str, max_words: int, mode: str | None = None,
                timeout: float = 30.0) -> dict:
        """One completion. Returns timing + token-count dict (see keys below)."""
        payload = {"task": "complete", "context": context,
                   "max_words": max_words, "lexicon": ""}
        if mode:
            payload["mode"] = mode
        assert self.proc.stdin and self.proc.stdout
        req = json.dumps(payload)
        self.proc.stdin.write(req + "\n")
        self.proc.stdin.flush()
        t0 = time.monotonic()

        ttft_ms = None          # first {"p":...} byte
        final_text = ""
        conf = 0.0
        n_partials = 0          # streamed-partial count (lower bound on emitted tokens)
        deadline = t0 + timeout
        while time.monotonic() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                break
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("p") is not None:          # streamed partial -> first one = TTFT
                if ttft_ms is None:
                    ttft_ms = (time.monotonic() - t0) * 1000.0
                n_partials += 1
                continue
            if obj.get("ok") is not None:         # final line
                total_ms = (time.monotonic() - t0) * 1000.0
                sug = obj.get("suggestion") or {}
                final_text = (sug.get("text") or "") if sug else ""
                conf = (sug.get("conf") if sug else None) or 0.0
                if ttft_ms is None:               # suppressed / no partial: TTFT == total
                    ttft_ms = total_ms
                # decode tokens: prefer word-count of the suggestion (the unit the
                # product cares about); n_partials is the streamed lower bound.
                out_words = len(final_text.split())
                return {
                    "ttft_ms": ttft_ms,
                    "total_ms": total_ms,
                    "decode_ms": max(0.0, total_ms - ttft_ms),
                    "out_words": out_words,
                    "n_partials": n_partials,
                    "conf": float(conf),
                    "text": final_text,
                }
        return {"ttft_ms": ttft_ms or (time.monotonic() - t0) * 1000.0,
                "total_ms": (time.monotonic() - t0) * 1000.0, "decode_ms": 0.0,
                "out_words": 0, "n_partials": n_partials, "conf": 0.0,
                "text": final_text, "timeout": True}

    def read_reuse_counter(self) -> dict | None:
        """Drain stderr and parse a prefix-reuse line IF the binary emits one.

        GROUND TRUTH for rank-1 lives in prepare_prompt() (scripts/llama_server.cpp:412)
        which currently emits NOTHING. The one-line instrumentation to add there is:

            fprintf(stderr, "REUSE common=%d len=%zu\\n", common, toks.size());

        Once present, this scrapes the last such line. Until then returns None and the
        harness falls back to the EXPECTED (self-constructed) hit rate. Non-blocking-ish:
        only called at teardown so we don't deadlock on the pipe.
        """
        if not self.proc.stderr:
            return None
        common = length = None
        try:
            # process already closing; read whatever is buffered
            for line in self.proc.stderr:
                if "REUSE" in line and "common=" in line:
                    try:
                        parts = dict(
                            p.split("=") for p in line.split() if "=" in p)
                        common = int(parts.get("common", common or 0))
                        length = int(parts.get("len", length or 0))
                    except Exception:
                        pass
        except Exception:
            pass
        if common is None:
            return None
        return {"common": common, "len": length or 0}

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=3)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


# =============================================================================
# incremental keystroke synthesis (warm-on scenario)
# =============================================================================
def keystroke_steps(context: str, step_tokens: int = 3, min_prefix_frac: float = 0.4):
    """Turn one static `context` into a growing-prefix keystroke stream.

    typed_eval.jsonl rows are INDEPENDENT prompts, not a keystroke stream. To exercise
    prefix reuse the way Typer hits it, replay each context as a prefix that grows by a
    few tokens per pause: start at min_prefix_frac of the text, then append ~step_tokens
    (~step_tokens*4 chars) until the full context is reached. Consecutive steps share a
    long common prefix -> prepare_prompt's `common` is large -> reuse fires.

    Yields (prefix_text, common_tokens_vs_prev, prefix_tokens) so the EXPECTED reuse
    hit-rate (common/len > 0.8) is computable without touching the binary.
    """
    n = len(context)
    if n == 0:
        return
    start = max(1, int(n * min_prefix_frac))
    step_chars = max(1, step_tokens * 4)
    prev_prefix = ""
    cut = start
    while True:
        cut = min(n, cut)
        prefix = context[:cut]
        # common prefix length (chars) with previous step, expressed in approx tokens
        c = 0
        m = min(len(prev_prefix), len(prefix))
        while c < m and prev_prefix[c] == prefix[c]:
            c += 1
        yield prefix, approx_tokens(prefix[:c]), approx_tokens(prefix)
        prev_prefix = prefix
        if cut >= n:
            break
        cut += step_chars


# =============================================================================
# scenarios
# =============================================================================
@dataclass
class CellConfig:
    model: Path
    server: Path
    data: Path
    scenario: str
    max_words: int
    n: int               # number of timed requests (warm) / contexts (cold)
    warmup: int          # discarded leading requests
    step_tokens: int
    mode: str | None     # None = full harness; "raw" = greedy baseline
    extra_env: dict
    idle_seconds: int


def load_contexts(data: Path, limit: int) -> list[dict]:
    rows = []
    for line in data.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("context"):
            rows.append(obj)
        if len(rows) >= limit:
            break
    return rows


def run_cold(cfg: CellConfig, rows: list[dict]) -> dict:
    """Fresh process per request: model load + Metal graph + first prefill in TTFT.

    Spawning a process per request is the only honest 'cold' on this binary (it has no
    'reset' command), and it's exactly what an app launch / helper respawn costs.
    """
    samples = []
    cold_n = min(cfg.n, len(rows))
    for i in range(cfg.warmup + cold_n):
        row = rows[i % len(rows)]
        h = Helper(cfg.server, cfg.model, cfg.extra_env)
        try:
            r = h.request(row["context"], cfg.max_words, cfg.mode)
        finally:
            h.close()
        if i >= cfg.warmup:
            samples.append(r)
    return summarize(samples, reuse=[])


def run_warm_off(cfg: CellConfig, rows: list[dict]) -> dict:
    """One warm process, INDEPENDENT prompts so `common` ~ 0: honest full-prefill cost."""
    h = Helper(cfg.server, cfg.model, cfg.extra_env)
    samples = []
    try:
        for i in range(cfg.warmup + cfg.n):
            row = rows[i % len(rows)]
            r = h.request(row["context"], cfg.max_words, cfg.mode)
            if i >= cfg.warmup:
                samples.append(r)
    finally:
        h.close()
    return summarize(samples, reuse=[])


def run_warm_on(cfg: CellConfig, rows: list[dict]) -> dict:
    """One warm process, INCREMENTAL replay: prefix reuse the way Typer hits it.

    For each context we replay a growing prefix; only the steps AFTER the first per
    context can reuse the previous step's KV (that's the realistic keystroke case).
    We also accumulate the EXPECTED hit-rate (common/len > 0.8) from the synthesized
    stream, since the binary doesn't yet emit the real counter.
    """
    h = Helper(cfg.server, cfg.model, cfg.extra_env)
    samples = []
    reuse_fracs: list[float] = []
    seen = 0
    try:
        for row in rows:
            first_step = True
            for prefix, common_tok, prefix_tok in keystroke_steps(
                    row["context"], cfg.step_tokens):
                r = h.request(prefix, cfg.max_words, cfg.mode)
                frac = (common_tok / prefix_tok) if prefix_tok else 0.0
                if not first_step:  # first step of a context can't reuse prior context
                    if seen >= cfg.warmup:
                        samples.append(r)
                        reuse_fracs.append(frac)
                first_step = False
                seen += 1
                if len(samples) >= cfg.n:
                    break
            if len(samples) >= cfg.n:
                break
        real = h.read_reuse_counter()  # ground truth if the binary was instrumented
    finally:
        h.close()
    out = summarize(samples, reuse=reuse_fracs)
    out["reuse_counter_source"] = "binary" if real else "expected(synthesized)"
    if real:
        out["reuse_counter_last"] = real
    return out


def run_idle_resume(cfg: CellConfig, rows: list[dict]) -> dict:
    """Warm, prime KV, sleep > residency keep-alive, then one request: eviction spike."""
    h = Helper(cfg.server, cfg.model, cfg.extra_env)
    samples = []
    try:
        ctx = rows[0]["context"]
        h.request(ctx, cfg.max_words, cfg.mode)          # prime
        time.sleep(cfg.idle_seconds)                     # > Metal keep-alive (default 180s)
        samples.append(h.request(ctx, cfg.max_words, cfg.mode))
    finally:
        h.close()
    out = summarize(samples, reuse=[])
    out["idle_seconds"] = cfg.idle_seconds
    return out


SCENARIOS = {
    "cold": run_cold,
    "warm-off": run_warm_off,
    "warm-on": run_warm_on,
    "idle-resume": run_idle_resume,
}


# =============================================================================
# summarize + result schema (the cross-backend contract)
# =============================================================================
def summarize(samples: list[dict], reuse: list[float]) -> dict:
    """Reduce raw per-request rows to the p50/p95 metric block shared with MLX."""
    if not samples:
        return {"n": 0, "note": "no samples (dry-run or all timed out)"}
    ttft = [s["ttft_ms"] for s in samples]
    total = [s["total_ms"] for s in samples]
    decode_ms = [s["decode_ms"] for s in samples]
    out_words = [s["out_words"] for s in samples]
    confs = [s["conf"] for s in samples]
    # decode tok/s over the suggestion: words / decode-seconds (word == product token unit).
    dtps = []
    for s in samples:
        if s["decode_ms"] > 0 and s["out_words"] > 0:
            dtps.append(s["out_words"] / (s["decode_ms"] / 1000.0))
    block = {
        "n": len(samples),
        "ttft_ms_p50": round(pct(ttft, 50), 2),
        "ttft_ms_p95": round(pct(ttft, 95), 2),
        "e2e_ms_p50": round(pct(total, 50), 2),
        "e2e_ms_p95": round(pct(total, 95), 2),
        "decode_ms_p50": round(pct(decode_ms, 50), 2),
        "decode_tps_p50": round(pct(dtps, 50), 2) if dtps else 0.0,
        "out_words_avg": round(statistics.mean(out_words), 2),
        "conf_avg": round(statistics.mean(confs), 4),
        # confidence-signal sanity hook (quality_check #4): distribution, not just mean.
        "conf_p50": round(pct(confs, 50), 4),
    }
    if reuse:
        hits = sum(1 for f in reuse if f > 0.8)
        block["prefix_reuse_hit_rate"] = round(hits / len(reuse), 4)
        block["prefix_reuse_frac_p50"] = round(pct(reuse, 50), 4)
    return block


def build_result(cfg: CellConfig, metrics: dict, model_info: dict,
                 binary_check: dict) -> dict:
    """The backend-neutral results document. An MLX harness emits the SAME shape."""
    return {
        "schema": SCHEMA_VERSION,
        "backend": "llama.cpp",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
        },
        "model": {
            "path": str(cfg.model),
            "name": cfg.model.name,
            "size_bytes": cfg.model.stat().st_size if cfg.model.exists() else None,
            "gguf": model_info,   # arch/size_label/block_count — confirm the 1.7B claim
        },
        "config": {
            "scenario": cfg.scenario,
            "mode": cfg.mode or "harness",
            "max_words": cfg.max_words,
            "max_tokens_clamp": clamp_max_tokens(cfg.max_words),
            "n": cfg.n,
            "warmup": cfg.warmup,
            "step_tokens": cfg.step_tokens,
            "data": str(cfg.data),
            "extra_env": cfg.extra_env,
        },
        # Which levers are env-controllable here vs need a scripts/build.sh rebuild,
        # plus what the binary actually reported at --check (compiled defaults).
        "levers": LEVER_NOTES,
        "binary_check": binary_check,
        "metrics": metrics,
    }


def server_check(server: Path, model: Path, extra_env: dict) -> dict:
    """Run the binary's `--check` to capture compiled defaults / load latency from stderr.

    The fairness note asks the binary to emit ttft_ms/prefill_tok/decode_tok at --check;
    today it emits 'loaded; sample=... latency_ms=N' and the chat_template. We parse what
    exists and record the rest as UNVERIFIED so the gap is explicit, not hidden.
    """
    out = {"latency_ms": None, "chat_template": None,
           "ttft_ms": "UNVERIFIED (binary --check does not emit ttft_ms yet)"}
    if not server.exists() or not model.exists():
        out["error"] = "server or model missing (dry-run)"
        return out
    env = os.environ.copy()
    env.update({k: str(v) for k, v in extra_env.items()})
    try:
        p = subprocess.run([str(server), "--model-path", str(model), "--check"],
                           capture_output=True, text=True, timeout=120, env=env)
        for line in (p.stderr or "").splitlines():
            if "latency_ms=" in line:
                for tok in line.split():
                    if tok.startswith("latency_ms="):
                        try:
                            out["latency_ms"] = int(tok.split("=", 1)[1])
                        except ValueError:
                            pass
            if line.startswith("chat_template="):
                out["chat_template"] = line.split("=", 1)[1][:120]
    except Exception as e:
        out["error"] = str(e)
    return out


# =============================================================================
# cli
# =============================================================================
def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", type=Path,
                    help="GGUF to bench (e.g. ~/Library/Application Support/typer/Models/typer-1l.gguf)")
    ap.add_argument("--server", type=Path, default=DEFAULT_SERVER,
                    help=f"typer-llama-server binary (default {DEFAULT_SERVER})")
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA,
                    help="typed_eval.jsonl (context/completion rows)")
    ap.add_argument("--scenario", choices=list(SCENARIOS), default="warm-on",
                    help="cold | warm-off | warm-on | idle-resume (never blends cold/warm)")
    ap.add_argument("--mode", choices=["harness", "raw"], default="harness",
                    help="harness = full product path; raw = greedy baseline (eval_compare)")
    ap.add_argument("--max-words", type=int, default=MAX_WORDS_DEFAULT)
    ap.add_argument("--n", type=int, default=50,
                    help="timed requests (protocol asks N>=50, p50/p95 not mean)")
    ap.add_argument("--warmup", type=int, default=2, help="discarded leading requests")
    ap.add_argument("--step-tokens", type=int, default=3,
                    help="warm-on: tokens appended per synthesized keystroke step")
    ap.add_argument("--limit", type=int, default=180,
                    help="max contexts to read from data (typed_eval has 180)")
    ap.add_argument("--idle-resume", action="store_true",
                    help="also run idle-resume (slow: sleeps --idle-seconds)")
    ap.add_argument("--idle-seconds", type=int, default=200,
                    help="idle-resume sleep; >180s (Metal residency keep-alive default)")
    # Lever env knobs surfaced as flags so a sweep is one command-line away.
    ap.add_argument("--keep-alive", type=int, default=None,
                    help="set GGML_METAL_RESIDENCY_KEEP_ALIVE_S (rank 2; e.g. 3600)")
    ap.add_argument("--out", type=Path, default=None,
                    help="results JSON path (default bench/results/<auto>.json)")
    ap.add_argument("--dry-run", action="store_true",
                    help="validate config + write a schema-only stub; NO model work")
    args = ap.parse_args()

    extra_env: dict = {}
    if args.keep_alive is not None:
        extra_env["GGML_METAL_RESIDENCY_KEEP_ALIVE_S"] = args.keep_alive

    # ---- dry-run: prove the schema + config without loading any weights -------
    if args.dry_run or not args.model:
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        stub_model = args.model or (DEFAULT_MODELS_DIR / "typer-1l.gguf")
        cfg = CellConfig(
            model=stub_model, server=args.server, data=args.data,
            scenario=args.scenario, max_words=args.max_words, n=args.n,
            warmup=args.warmup, step_tokens=args.step_tokens,
            mode=None if args.mode == "harness" else "raw",
            extra_env=extra_env, idle_seconds=args.idle_seconds)
        result = build_result(
            cfg, metrics={"n": 0, "note": "dry-run: no model executed"},
            model_info=gguf_arch(stub_model) if stub_model.exists() else
            {"note": "model not present; metadata skipped"},
            binary_check={"note": "dry-run: --check not executed"})
        out = args.out or (RESULTS_DIR / f"dryrun_{args.scenario}_{args.mode}.json")
        out.write_text(json.dumps(result, indent=2))
        print(f"[dry-run] config valid. schema={SCHEMA_VERSION}")
        print(f"[dry-run] server present: {args.server.exists()}  ({args.server})")
        print(f"[dry-run] data present:   {args.data.exists()}  ({args.data})")
        print(f"[dry-run] model present:  {stub_model.exists()}  ({stub_model})")
        print(f"[dry-run] wrote schema stub -> {out}")
        if not args.model:
            print("[dry-run] (no --model given; pass one for a real run)")
        return 0

    # ---- real run -------------------------------------------------------------
    if not args.server.exists():
        print(f"server not found: {args.server}\nBuild it: scripts/build.sh", file=sys.stderr)
        return 2
    if not args.model.exists():
        print(f"model not found: {args.model}", file=sys.stderr)
        return 2
    if not args.data.exists():
        print(f"data not found: {args.data}", file=sys.stderr)
        return 2

    rows = load_contexts(args.data, args.limit)
    if not rows:
        print("no contexts in --data", file=sys.stderr)
        return 2

    cfg = CellConfig(
        model=args.model, server=args.server, data=args.data,
        scenario=args.scenario, max_words=args.max_words, n=args.n,
        warmup=args.warmup, step_tokens=args.step_tokens,
        mode=None if args.mode == "harness" else "raw",
        extra_env=extra_env, idle_seconds=args.idle_seconds)

    print(f"[bench] model={args.model.name} scenario={args.scenario} mode={args.mode} n={args.n}",
          file=sys.stderr)
    model_info = gguf_arch(args.model)
    if model_info.get("architecture"):
        print(f"[bench] gguf arch={model_info.get('architecture')} "
              f"size_label={model_info.get('size_label')} "
              f"layers={model_info.get('block_count')}", file=sys.stderr)
    binary_check = server_check(args.server, args.model, extra_env)

    metrics = SCENARIOS[args.scenario](cfg, rows)
    if args.idle_resume and args.scenario != "idle-resume":
        metrics = {"_primary": metrics,
                   "idle_resume": run_idle_resume(cfg, rows)}

    result = build_result(cfg, metrics, model_info, binary_check)
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    out = args.out or (RESULTS_DIR /
                       f"{args.model.stem}_{args.scenario}_{args.mode}.json")
    out.write_text(json.dumps(result, indent=2))
    print(json.dumps(metrics, indent=2))
    print(f"[bench] wrote -> {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
