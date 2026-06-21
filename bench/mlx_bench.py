#!/usr/bin/env python3
"""MLX TTFT/throughput bench for Typer's incremental-autocomplete workload.

THE product metric is TTFT (time-to-first-token): ghost text must land in ~100ms or
the user has typed past it. This is the MLX (mlx-lm) side of a two-backend comparison;
the llama.cpp side is bench/llamacpp_bench.py. Both emit the SAME results JSON shape
(SCHEMA_VERSION below, defined in bench/README.md) so cells diff one-for-one.

It measures, over the realistic prompts in training/data/typed_eval.jsonl: TTFT
(p50/p95), decode tok/s, end-to-end suggestion latency, peak memory, and — the #1 TTFT
lever — KV PREFIX REUSE on the incremental prompt.

CRITICAL MLX DETAIL (verified, mlx-lm 0.31.x)
---------------------------------------------
mlx_lm's generate_step does NOT value-match a prefix on its own: given a populated
prompt_cache it still prefills the ENTIRE prompt array you pass it. To reproduce the
C++ helper's prepare_prompt() (scripts/llama_server.cpp:412) — count the common token
prefix vs the previous prompt, drop the diverged KV cells, decode ONLY the suffix — we
do that bookkeeping here: common_prefix_len() + trim_prompt_cache() + feed the suffix.
Without it the "warm" numbers would be meaningless. This mirrors the llama.cpp lane,
where the binary's own prepare_prompt() does the equivalent.

TTFT MEASUREMENT BOUNDARY (fairness)
------------------------------------
We measure TTFT in-process at the FIRST token yielded by stream_generate — defined to
be equivalent to the llama.cpp lane's first-`{"p":...}`-byte-on-stdout. We run MLX
in-process (NOT mlx_lm.server) so there is no HTTP/IPC layer to subtract, matching the
helper's in-process measurement (see README "Fairness rules").

SCENARIOS (never blend cold and warm):
  cold        — fresh model + fresh cache per request: includes the MLX Metal graph
                compile spike on the first decode (warm it with --warmup-dummy and the
                effect is recorded both ways).
  warm-off    — one warm model, INDEPENDENT prompts, fresh cache each call: the honest
                full-prefill cost after an app switch / big edit.
  warm-on     — one warm model, INCREMENTAL replay: each typed_eval context is replayed
                as a growing prefix (append a few tokens/step) so KV prefix reuse fires
                the way Typer hits it keystroke-to-keystroke. THE scenario users live in.
  idle-resume — warm, prime KV, sleep --idle-seconds (>180s Metal residency keep-alive),
                then one request: the residency-eviction TTFT spike.

QUANT
-----
MLX weight quant is fixed at convert time (mlx_lm.convert -q --q-bits), not load time,
so pass an already-converted model dir and label it with --quant for the results file.
KV-cache quant IS a runtime knob (--kv-bits / --kv-group-size): the cross-cutting
sub-axis applied to the WINNING weight quant only — do not sweep it across every cell.

DRY-VALIDATION ONLY: this script never downloads weights; `--help` and `--dry-run` do
no model work. A real run needs a local MLX model dir (or HF id) via --model. mlx-lm
lives in training/.venv.

Run:  uv run bench/mlx_bench.py --model <mlx_path_or_hf_id> --scenario warm-on
"""
from __future__ import annotations

import argparse
import importlib
import json
import os
import platform
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

# --- repo-relative anchors (this file lives at <repo>/bench/) -----------------
REPO = Path(__file__).resolve().parent.parent
DEFAULT_DATA = REPO / "training" / "data" / "typed_eval.jsonl"
DEFAULT_MODELS_DIR = Path.home() / "Library" / "Application Support" / "typer" / "Models"
RESULTS_DIR = REPO / "bench" / "results"

# Must match bench/llamacpp_bench.py so the two backends share one schema.
SCHEMA_VERSION = "typer-bench/1"

# The C++ binary clamps generated tokens to clamp(max_words + 7, 8, 18). Mirror that
# EXACTLY so decode-token accounting agrees with the llama.cpp lane (fairness).
MAX_WORDS_DEFAULT = 7

# C++ stable_tail caps context at 2200 chars (llama_server.cpp:596); match it so prompt
# lengths are comparable across backends.
MAX_CONTEXT_CHARS = 2200


def clamp_max_tokens(max_words: int) -> int:
    """Mirror llama_server.cpp:613 — int max_tokens = clamp(max_words + 7, 8, 18)."""
    return max(8, min(18, max_words + 7))


# MLX-side lever provenance, recorded into every result (parallels llamacpp's LEVER_NOTES).
LEVER_NOTES = {
    "prefix_reuse": "harness-implemented: common_prefix_len + trim_prompt_cache (rank 1)",
    "kv_bits": "runtime (--kv-bits; rank 6 KV-quant sub-axis, winning weight quant only)",
    "wired_limit_mb": "runtime (mx.set_wired_limit; keep weights resident, avoid paging)",
    "weight_quant": "convert-time only (mlx_lm.convert -q --q-bits); pass a converted dir",
    "n_ctx": "soft (autocomplete prompts are well under; cache is unbounded KVCache)",
    "graph_compile": "MLX compiles the Metal graph on first decode (~0.5-2s); --warmup-dummy absorbs it",
}


# =============================================================================
# helpers: percentiles (identical to llamacpp_bench.pct for cross-backend parity)
# =============================================================================
def pct(values: list[float], p: float) -> float:
    """p50/p95 the same way llamacpp_bench.py / training/eval.py do (nearest-rank)."""
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, int(round((p / 100) * (len(s) - 1))))
    return s[k]


def common_prefix_len(a: list[int], b: list[int]) -> int:
    """Length of the shared leading token run — the C++ prepare_prompt() `common`."""
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


# =============================================================================
# data + incremental keystroke synthesis (warm-on scenario)
# =============================================================================
def load_contexts(data: Path, limit: int) -> list[dict]:
    rows = []
    for line in data.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        ctx = obj.get("context")
        if ctx:
            if len(ctx) > MAX_CONTEXT_CHARS:  # match C++ stable_tail cap
                obj["context"] = ctx[-MAX_CONTEXT_CHARS:]
            rows.append(obj)
        if len(rows) >= limit:
            break
    return rows


def keystroke_steps(tokens: list[int], step_tokens: int, min_prefix_frac: float = 0.4):
    """Turn one tokenized context into a growing-prefix keystroke stream.

    typed_eval.jsonl rows are INDEPENDENT prompts, not a keystroke stream. To exercise
    prefix reuse the way Typer hits it, replay each context as a prefix that grows by a
    few tokens per pause: start at min_prefix_frac of the tokens, then append
    ~step_tokens until the full context is reached. Consecutive steps share a long
    common prefix -> trim_prompt_cache keeps it -> reuse fires.

    Mirrors llamacpp_bench.keystroke_steps but operates on REAL tokens (we have the
    tokenizer here) instead of a ~4-chars/token approximation, so the reuse accounting
    is exact on the MLX side. Yields lists of token ids (the growing prefixes).
    """
    n = len(tokens)
    if n == 0:
        return
    start = max(1, int(n * min_prefix_frac))
    cut = start
    step = max(1, step_tokens)
    while True:
        cut = min(n, cut)
        yield tokens[:cut]
        if cut >= n:
            break
        cut += step


# =============================================================================
# the MLX engine (in-process; lazy imports so --help / --dry-run need no MLX)
# =============================================================================
class MlxEngine:
    """Loads an MLX model once and decodes suggestions one request at a time.

    Timing boundary (THE product metric): t0 is the instant before generation starts;
    TTFT is the wall time to the FIRST token yielded by stream_generate — the MLX
    analogue of the helper's first-byte-on-stdout. The final yield bounds end-to-end.
    """

    def __init__(self, model_path: str, max_words: int,
                 kv_bits: Optional[int], kv_group_size: int,
                 wired_limit_mb: int):
        self.mx = importlib.import_module("mlx.core")
        mlx_lm = importlib.import_module("mlx_lm")
        self.cache_mod = importlib.import_module("mlx_lm.models.cache")
        self.sample_utils = importlib.import_module("mlx_lm.sample_utils")
        self._load = mlx_lm.load
        self._stream_generate = mlx_lm.stream_generate

        self.kv_bits = kv_bits
        self.kv_group_size = kv_group_size
        self.max_tokens = clamp_max_tokens(max_words)
        # Greedy/deterministic (temp 0): matches the speed protocol and keeps the
        # separate quality pass (training/eval_compare.py) reproducible.
        self.sampler = self.sample_utils.make_sampler(temp=0.0)
        self.notes: list[str] = []

        # Wired memory: keep weights resident so the OS can't page them out — a TTFT
        # killer for an always-on helper. Best-effort; driver may reject the limit.
        if wired_limit_mb and wired_limit_mb > 0:
            try:
                self.mx.set_wired_limit(wired_limit_mb * 1024 * 1024)
                self.notes.append(f"wired_limit_mb={wired_limit_mb}")
            except Exception as e:  # pragma: no cover - driver dependent
                self.notes.append(f"set_wired_limit_failed={e}")

        t0 = time.monotonic()
        self.model, self.tokenizer = self._load(model_path)
        self.notes.append(f"model_load_ms={(time.monotonic() - t0) * 1000.0:.1f}")

    # -- tokenization (keep the model's own BOS behaviour, like the C++ add_special) --
    def tokenize(self, text: str) -> list[int]:
        return list(self.tokenizer.encode(text))

    def fresh_cache(self):
        # Unbounded KVCache; becomes a QuantizedKVCache lazily inside generate_step when
        # kv_bits is set. Autocomplete prompts are far under any sane n_ctx, so we don't
        # cap max_kv_size (a cap would force a RotatingKVCache that can't be value-trimmed).
        return self.cache_mod.make_prompt_cache(self.model)

    def decode(self, prompt_tokens: list[int], prompt_cache,
               last_tokens: Optional[list[int]]) -> dict:
        """Decode one suggestion. Reuse the KV prefix when prompt_cache + last_tokens
        are supplied; otherwise full-prefill the whole prompt.

        Returns the same per-request keys the llama.cpp lane returns (ttft_ms, total_ms,
        decode_ms, out_words, n_partials, conf, text) PLUS reuse accounting
        (prefill_tok, reused_tok, prompt_tok) which MLX can measure exactly.
        """
        mx = self.mx
        reused = 0
        total_len = len(prompt_tokens)

        if prompt_cache is not None and last_tokens:
            common = common_prefix_len(last_tokens, prompt_tokens)
            # C++ guard (llama_server.cpp:419): always re-decode at least the final
            # prompt token so logits correspond to THIS prompt, not a stale cell.
            if common > 0:
                common = min(common, total_len - 1)
            if common > 0 and self.cache_mod.can_trim_prompt_cache(prompt_cache):
                # Cache holds KV for last_tokens; trim back to `common` and feed the suffix.
                to_trim = len(last_tokens) - common
                if to_trim > 0:
                    self.cache_mod.trim_prompt_cache(prompt_cache, to_trim)
                reused = common
                feed = prompt_tokens[common:]
            else:
                feed = prompt_tokens
        else:
            feed = prompt_tokens

        prefill_tok = len(feed)
        prompt_arr = mx.array(feed)

        kwargs: dict[str, Any] = dict(
            max_tokens=self.max_tokens, sampler=self.sampler, prompt_cache=prompt_cache,
        )
        if self.kv_bits:
            kwargs["kv_bits"] = self.kv_bits
            kwargs["kv_group_size"] = self.kv_group_size

        # --- timed region ---
        t0 = time.monotonic()
        ttft_ms: Optional[float] = None
        pieces: list[str] = []
        n_tokens = 0
        for resp in self._stream_generate(self.model, self.tokenizer, prompt_arr, **kwargs):
            if ttft_ms is None:
                ttft_ms = (time.monotonic() - t0) * 1000.0
            if resp.text:
                pieces.append(resp.text)
            n_tokens += 1
            if resp.finish_reason is not None:
                break
        total_ms = (time.monotonic() - t0) * 1000.0
        if ttft_ms is None:  # produced nothing
            ttft_ms = total_ms

        text = "".join(pieces).strip()
        # first line only (autocomplete is one line), to match the helper's shaping
        nl = text.find("\n")
        if nl != -1:
            text = text[:nl].strip()
        out_words = len(text.split())
        return {
            "ttft_ms": ttft_ms,
            "total_ms": total_ms,
            "decode_ms": max(0.0, total_ms - ttft_ms),
            "out_words": out_words,
            "n_partials": n_tokens,          # streamed token count (decode-token unit)
            "conf": 0.0,                     # MLX path doesn't compute the prob signal here
            "text": text,
            "prompt_tok": total_len,
            "prefill_tok": prefill_tok,
            "reused_tok": reused,
        }


# =============================================================================
# scenarios (names + warmup discard identical to bench/llamacpp_bench.py)
# =============================================================================
@dataclass
class CellConfig:
    model: str
    data: Path
    scenario: str
    max_words: int
    n: int
    warmup: int
    step_tokens: int
    kv_bits: Optional[int]
    kv_group_size: int
    wired_limit_mb: int
    warmup_dummy: bool
    idle_seconds: int
    limit: int
    quant: str


def _maybe_dummy_warmup(eng: MlxEngine, contexts: list[str]) -> None:
    """Absorb the MLX Metal graph-compile spike with a throwaway decode (recorded)."""
    cache = eng.fresh_cache()
    toks = eng.tokenize(contexts[0])[:8] or [0]
    r = eng.decode(toks, cache, None)
    eng.notes.append(f"dummy_warmup_ttft_ms={r['ttft_ms']:.1f}")


def run_cold(eng: MlxEngine, cfg: CellConfig, rows: list[dict]) -> dict:
    """Fresh CACHE per request: first decode includes the Metal graph compile.

    NOTE: MLX runs in-process, so unlike the llama.cpp lane we cannot respawn the
    process per request without paying a multi-second reload that dwarfs TTFT. The
    honest in-process 'cold' is a fresh prompt cache each call (no KV reuse, graph
    rebuilt for a new prompt shape). The very first request also carries the one-time
    graph compile; we keep --warmup-dummy OFF here so that spike is visible, and the
    note records the load time separately.
    """
    samples = []
    cold_n = min(cfg.n, len(rows))
    for i in range(cfg.warmup + cold_n):
        row = rows[i % len(rows)]
        cache = eng.fresh_cache()
        r = eng.decode(eng.tokenize(row["context"]), cache, None)
        if i >= cfg.warmup:
            samples.append(r)
    return summarize(samples, reuse=[])


def run_warm_off(eng: MlxEngine, cfg: CellConfig, rows: list[dict]) -> dict:
    """One warm model, INDEPENDENT prompts, fresh cache each call: full-prefill cost."""
    if cfg.warmup_dummy:
        _maybe_dummy_warmup(eng, [r["context"] for r in rows])
    samples = []
    for i in range(cfg.warmup + cfg.n):
        row = rows[i % len(rows)]
        cache = eng.fresh_cache()  # OFF: no reuse across requests
        r = eng.decode(eng.tokenize(row["context"]), cache, None)
        if i >= cfg.warmup:
            samples.append(r)
    return summarize(samples, reuse=[])


def run_warm_on(eng: MlxEngine, cfg: CellConfig, rows: list[dict]) -> dict:
    """One warm model, INCREMENTAL replay: prefix reuse the way Typer hits it.

    Per context we replay a growing prefix; only the steps AFTER the first per context
    reuse the previous step's KV (the realistic keystroke case). Reuse here is EXACT
    (we own the tokenizer): reused_tok / prompt_tok is the real common/len, so
    common/len > 0.8 is the ground-truth hit-rate — the rank-1 verification the
    llama.cpp lane can only approximate until its binary emits the counter.
    """
    if cfg.warmup_dummy:
        _maybe_dummy_warmup(eng, [r["context"] for r in rows])
    samples: list[dict] = []
    reuse_fracs: list[float] = []
    seen = 0
    for row in rows:
        tokens = eng.tokenize(row["context"])
        cache = eng.fresh_cache()  # new context -> new cache (prefix diverges at token 0)
        last: Optional[list[int]] = None
        first_step = True
        for prefix in keystroke_steps(tokens, cfg.step_tokens):
            r = eng.decode(prefix, cache, last)
            last = prefix
            frac = (r["reused_tok"] / r["prompt_tok"]) if r["prompt_tok"] else 0.0
            if not first_step:  # first step of a context can't reuse prior context
                if seen >= cfg.warmup:
                    samples.append(r)
                    reuse_fracs.append(frac)
                seen += 1
            first_step = False
            if len(samples) >= cfg.n:
                break
        if len(samples) >= cfg.n:
            break
    out = summarize(samples, reuse=reuse_fracs)
    out["reuse_counter_source"] = "exact(mlx-tokenized)"
    return out


def run_idle_resume(eng: MlxEngine, cfg: CellConfig, rows: list[dict]) -> dict:
    """Warm, prime KV, sleep > residency keep-alive, then one request: eviction spike."""
    tokens = eng.tokenize(rows[0]["context"])
    cache = eng.fresh_cache()
    eng.decode(tokens, cache, None)            # prime
    time.sleep(cfg.idle_seconds)               # > Metal keep-alive (default 180s)
    r = eng.decode(tokens, cache, tokens)      # same prompt -> reuse path; spike = eviction
    out = summarize([r], reuse=[])
    out["idle_seconds"] = cfg.idle_seconds
    return out


SCENARIOS = {
    "cold": run_cold,
    "warm-off": run_warm_off,
    "warm-on": run_warm_on,
    "idle-resume": run_idle_resume,
}


# =============================================================================
# summarize + result schema (the cross-backend contract — keys match llamacpp)
# =============================================================================
def summarize(samples: list[dict], reuse: list[float]) -> dict:
    """Reduce raw per-request rows to the p50/p95 metric block shared with llama.cpp."""
    if not samples:
        return {"n": 0, "note": "no samples (dry-run or all empty)"}
    ttft = [s["ttft_ms"] for s in samples]
    total = [s["total_ms"] for s in samples]
    decode_ms = [s["decode_ms"] for s in samples]
    out_words = [s["out_words"] for s in samples]
    confs = [s["conf"] for s in samples]
    # decode tok/s over the suggestion: streamed tokens / decode-seconds.
    dtps = []
    for s in samples:
        if s["decode_ms"] > 0 and s["n_partials"] > 0:
            dtps.append(s["n_partials"] / (s["decode_ms"] / 1000.0))
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
        "conf_p50": round(pct(confs, 50), 4),
        # MLX measures effective prefill / reuse EXACTLY (it owns the tokenizer).
        "effective_prefill_tok_avg": round(
            statistics.mean([s["prefill_tok"] for s in samples]), 2),
        "tokens_skipped_avg": round(
            statistics.mean([s["reused_tok"] for s in samples]), 2),
    }
    if reuse:
        hits = sum(1 for f in reuse if f > 0.8)
        block["prefix_reuse_hit_rate"] = round(hits / len(reuse), 4)
        block["prefix_reuse_frac_p50"] = round(pct(reuse, 50), 4)
    return block


def build_result(cfg: CellConfig, metrics: dict, engine_notes: list[str],
                 peak_mem_mb: Optional[float]) -> dict:
    """The backend-neutral results document — SAME shape as llamacpp_bench.build_result."""
    mlx_lm_version = mlx_version = None
    try:
        mlx_lm_version = getattr(importlib.import_module("mlx_lm"), "__version__", None)
        mlx_version = importlib.import_module("mlx.core").__version__
    except Exception:
        pass
    model_path = Path(cfg.model)
    return {
        "schema": SCHEMA_VERSION,
        "backend": "mlx",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
            "mlx_lm_version": mlx_lm_version,
            "mlx_version": mlx_version,
        },
        "model": {
            "path": cfg.model,
            "name": model_path.name,
            "size_bytes": (model_path.stat().st_size
                           if model_path.exists() and model_path.is_file() else None),
            "weight_quant": cfg.quant,   # label only (MLX quant is convert-time)
            "kv_quant": (f"kv_bits={cfg.kv_bits}" if cfg.kv_bits else "f16"),
        },
        "config": {
            "scenario": cfg.scenario,
            "mode": "harness",   # MLX lane is greedy in-process; mirrors raw-ish decode
            "max_words": cfg.max_words,
            "max_tokens_clamp": clamp_max_tokens(cfg.max_words),
            "n": cfg.n,
            "warmup": cfg.warmup,
            "step_tokens": cfg.step_tokens,
            "kv_bits": cfg.kv_bits,
            "kv_group_size": cfg.kv_group_size,
            "wired_limit_mb": cfg.wired_limit_mb,
            "warmup_dummy": cfg.warmup_dummy,
            "data": str(cfg.data),
        },
        "levers": LEVER_NOTES,
        "engine_notes": engine_notes,
        "peak_memory_mb": peak_mem_mb,
        "metrics": metrics,
    }


# =============================================================================
# cli
# =============================================================================
def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model",
                    help="MLX model dir (already quantized) or HF repo id "
                         "(e.g. ~/Library/Application Support/typer/Models/Qwen3-1.7B-8bit)")
    ap.add_argument("--quant", default="unknown",
                    help="weight-quant LABEL for the results file (fp16/q8/q4); MLX "
                         "quant is fixed at convert time, this is metadata only")
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA,
                    help="typed_eval.jsonl (context/completion rows)")
    ap.add_argument("--scenario", choices=list(SCENARIOS), default="warm-on",
                    help="cold | warm-off | warm-on | idle-resume (never blends cold/warm)")
    ap.add_argument("--max-words", type=int, default=MAX_WORDS_DEFAULT)
    ap.add_argument("--n", type=int, default=50,
                    help="timed requests (protocol asks N>=50, p50/p95 not mean)")
    ap.add_argument("--warmup", type=int, default=2, help="discarded leading requests")
    ap.add_argument("--step-tokens", type=int, default=3,
                    help="warm-on: tokens appended per synthesized keystroke step")
    ap.add_argument("--limit", type=int, default=180,
                    help="max contexts to read from data (typed_eval has 180)")
    # rank-6 KV-quant sub-axis (winning weight quant only).
    ap.add_argument("--kv-bits", type=int, default=None, choices=[4, 8],
                    help="quantize KV cache to N bits (rank 6); omit for f16 KV")
    ap.add_argument("--kv-group-size", type=int, default=64,
                    help="KV quant group size (MLX default 64)")
    # other levers.
    ap.add_argument("--wired-limit-mb", type=int, default=0,
                    help="mx.set_wired_limit in MB (0 = leave default); keep weights resident")
    ap.add_argument("--warmup-dummy", action="store_true",
                    help="run a throwaway decode first to absorb the Metal graph-compile spike")
    ap.add_argument("--idle-seconds", type=int, default=200,
                    help="idle-resume sleep; >180s (Metal residency keep-alive default)")
    ap.add_argument("--out", type=Path, default=None,
                    help="results JSON path (default bench/results/<auto>.json)")
    ap.add_argument("--dry-run", action="store_true",
                    help="validate config + write a schema-only stub; NO model work")
    args = ap.parse_args()

    cfg = CellConfig(
        model=args.model or str(DEFAULT_MODELS_DIR / "Qwen3-1.7B-8bit"),
        data=args.data, scenario=args.scenario, max_words=args.max_words,
        n=args.n, warmup=args.warmup, step_tokens=args.step_tokens,
        kv_bits=args.kv_bits, kv_group_size=args.kv_group_size,
        wired_limit_mb=args.wired_limit_mb, warmup_dummy=args.warmup_dummy,
        idle_seconds=args.idle_seconds, limit=args.limit, quant=args.quant)

    # ---- dry-run: prove the schema + config without loading any weights -------
    if args.dry_run or not args.model:
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        result = build_result(
            cfg, metrics={"n": 0, "note": "dry-run: no model executed"},
            engine_notes=["dry-run: MLX not imported, no weights loaded"],
            peak_mem_mb=None)
        out = args.out or (RESULTS_DIR / f"dryrun_mlx_{args.scenario}.json")
        out.write_text(json.dumps(result, indent=2))
        print(f"[dry-run] config valid. schema={SCHEMA_VERSION}")
        print(f"[dry-run] data present:  {args.data.exists()}  ({args.data})")
        print(f"[dry-run] model present: {Path(cfg.model).exists()}  ({cfg.model})")
        print(f"[dry-run] wrote schema stub -> {out}")
        if not args.model:
            print("[dry-run] (no --model given; pass one for a real run)")
        return 0

    # ---- real run -------------------------------------------------------------
    if not args.data.exists():
        print(f"data not found: {args.data}", file=sys.stderr)
        return 2
    rows = load_contexts(args.data, args.limit)
    if not rows:
        print("no contexts in --data", file=sys.stderr)
        return 2

    print(f"[bench] model={Path(cfg.model).name} scenario={cfg.scenario} "
          f"quant={cfg.quant} kv_bits={cfg.kv_bits} n={cfg.n}", file=sys.stderr)

    eng = MlxEngine(cfg.model, cfg.max_words, cfg.kv_bits, cfg.kv_group_size,
                    cfg.wired_limit_mb)
    eng.mx.reset_peak_memory()
    metrics = SCENARIOS[cfg.scenario](eng, cfg, rows)
    peak_mem_mb = eng.mx.get_peak_memory() / (1024 * 1024)

    result = build_result(cfg, metrics, eng.notes, round(peak_mem_mb, 1))
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    model_tag = Path(cfg.model).name
    kv = f"_kv{cfg.kv_bits}" if cfg.kv_bits else ""
    out = args.out or (RESULTS_DIR / f"mlx_{model_tag}_{cfg.quant}_{cfg.scenario}{kv}.json")
    out.write_text(json.dumps(result, indent=2))
    print(json.dumps(metrics, indent=2))
    print(f"[bench] peak_mem={peak_mem_mb:.1f}MB  wrote -> {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
