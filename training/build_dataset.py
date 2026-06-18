#!/usr/bin/env python3
"""Build autocomplete training sets from Typer's on-device data + public corpora.

This is the bridge between the app's local capture (TrainingLog.swift) and any
fine-tuning stack. It emits examples in the SAME prompt shape the model sees at
inference: labeled context blocks joined by blank lines, with the live text last,
which the model continues. The runtime prepends "<bos>" itself, so we never write it.

Three sources, all optional — the script uses whatever is present:

  1. training.jsonl  — the live capture: (context, suggestion, accepted?, words...).
                       Accepted suggestions become SFT positives; every record becomes
                       a KTO example (label = accepted); contexts seen with both an
                       accepted and a rejected suggestion become DPO pairs.
  2. style.txt       — the user's own writing ("category\\ttext"). Each line is sliced
                       at word boundaries into prefix -> 5-7-word continuation SFT
                       positives (real human continuations; no reward label).
  3. --corpus DIR    — any directory of .txt/.jsonl public-corpus text, sliced the
                       same way. This is how you mix in FineWeb/email/chat/etc.

Outputs (JSONL, under --out):
  sft.jsonl   {"prompt": str, "completion": str}                 # supervised targets
  kto.jsonl   {"prompt": str, "completion": str, "label": bool}  # unpaired reward
  dpo.jsonl   {"prompt": str, "chosen": str, "rejected": str}    # paired preference
  stats.json  counts per source/category

Stdlib only — run it with `uv run training/build_dataset.py` (or plain python3).
No model, no network. See training/README.md for where each output feeds.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
import zlib
from collections import defaultdict
from pathlib import Path

# Default location of the app's on-device data.
APP_DIR = Path.home() / "Library" / "Application Support" / "typer"

# Representative app names per coarse category, so training prompts resemble the real
# inference distribution (the app writes the real app name into "Writing app: …").
# Rotated deterministically per example so the model conditions on the category rather
# than memorizing one name.
CATEGORY_APPS = {
    "chat": ["Messages", "Slack", "Discord", "WhatsApp", "Telegram"],
    "email": ["Mail", "Outlook", "Spark", "Superhuman"],
    "docs": ["Notes", "Obsidian", "Pages", "Notion", "Bear"],
    "code": ["Xcode", "VS Code", "Cursor", "Zed"],
    "browser": ["Safari", "Chrome", "Arc", "Firefox"],
    "other": [],
}

WORD_RE = re.compile(r"\S+\s*")

# Defense-in-depth secret screen, mirroring TrainingLog.looksSensitive in the app. The
# app already drops these at capture time; this re-screens in case of older (v1) records
# or hand-added corpus so no credential-shaped text reaches a training file.
_SENSITIVE = re.compile(
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"   # email
    r"|https?://|www\."                                   # url
    r"|[0-9]{4,}"                                          # 4+ digit run
    r"|[A-Za-z0-9+/=_-]{20,}"                             # long token (keys/hashes)
    r"|(?:/[A-Za-z0-9._~-]+){2,}"                         # filesystem path
)


def looks_sensitive(s: str) -> bool:
    return bool(s) and _SENSITIVE.search(s) is not None


def format_prompt(context: str, category: str, idx: int) -> str:
    """Mirror TyperApp.assembledContext: optional 'Writing app:' header, blank-line
    separated, with the live text last. We only have the immediate context + category
    here (style/window blocks are personalization the model continues regardless)."""
    context = context.strip("\n")
    if not context:
        return ""
    blocks: list[str] = []
    apps = CATEGORY_APPS.get(category, [])
    if apps:
        blocks.append(f"Writing app: {apps[idx % len(apps)]}")
    blocks.append(context)
    return "\n\n".join(blocks)


def first_words(text: str, n: int) -> str:
    """First `n` whitespace-delimited words, preserving original spacing/punctuation."""
    if n <= 0:
        return ""
    out, count = [], 0
    for m in WORD_RE.finditer(text):
        out.append(m.group(0))
        count += 1
        if count >= n:
            break
    return "".join(out).rstrip()


def word_count(text: str) -> int:
    return len(text.split())


def classify(rec: dict) -> tuple[str, float, int]:
    """Map one capture record (schema v2) to (klass, weight, kept_words).

    klass ∈ {positive, negative, neutral}; weight ≈ information gain. This is where the
    RL review's corrections live:
      - Tab/backtick accepts are REAL gain (the user did not type those words) → strong
        positive, weighted by words inserted.
      - A long type-through (≥3 words matched) is a weak positive.
      - A SHORT type-through (1–2 words) carries ~no information — the user would have
        typed it anyway — so it is dropped (neutral), not rewarded.
      - A below-gate / never-shown row (exploration) is a weak negative that lets the
        trainer + calibration see the suppressed region instead of only survivors.
    v1 records (no accept_kind/shown/exploration) fall back to accepted→positive."""
    accepted = bool(rec.get("accepted"))
    shown = rec.get("shown", True)
    exploration = rec.get("exploration", False)
    kind = rec.get("accept_kind") or ("tab" if accepted else "none")  # v1 fallback
    wa = int(rec.get("words_accepted") or 0)
    if exploration or not shown:
        return ("negative", 0.5, 0)
    if not accepted:
        return ("negative", 1.0, 0)
    if kind in ("tab", "backtick"):
        return ("positive", float(max(1, wa)), wa)
    if kind == "typethrough":
        return ("positive", 0.5, wa) if wa >= 3 else ("neutral", 0.0, 0)
    return ("positive", float(max(1, wa)), wa)  # v1 accepted, unknown kind


def slice_line(
    text: str, category: str, idx: int, rng: random.Random,
    min_ctx_words: int, comp_words: tuple[int, int],
) -> list[dict]:
    """Turn one human-written line into prefix -> short-continuation SFT positives.

    Picks a few cut points across the line; the prefix becomes the context, the next
    5-7 words become the gold continuation — exactly the inline-completion task."""
    words = text.split()
    if len(words) < min_ctx_words + comp_words[0]:
        return []
    out = []
    # A couple of cuts per line (more for long lines), spread across it.
    n_cuts = min(3, max(1, len(words) // 12))
    for _ in range(n_cuts):
        lo = min_ctx_words
        hi = len(words) - comp_words[0]
        if hi <= lo:
            break
        cut = rng.randint(lo, hi)
        ctx = " ".join(words[:cut])
        target_words = rng.randint(comp_words[0], comp_words[1])
        comp = " ".join(words[cut:cut + target_words])
        prompt = format_prompt(ctx, category, idx)
        if prompt and comp:
            # The runtime emits a leading space when continuing mid-word; here prefixes
            # always end at a word boundary, so the continuation leads with a space.
            out.append({"prompt": prompt, "completion": " " + comp})
    return out


def iter_corpus_texts(corpus_dir: Path):
    """Yield (text, category) from .txt (one doc per file, split on blank lines) and
    .jsonl (expects a 'text' field, optional 'category')."""
    for p in sorted(corpus_dir.rglob("*")):
        if p.suffix == ".txt":
            try:
                blob = p.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for para in re.split(r"\n\s*\n", blob):
                para = para.strip()
                if para:
                    yield para, "other"
        elif p.suffix == ".jsonl":
            try:
                for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    obj = json.loads(line)
                    txt = (obj.get("text") or "").strip()
                    if txt:
                        yield txt, obj.get("category", "other")
            except (OSError, json.JSONDecodeError):
                continue


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app-dir", type=Path, default=APP_DIR,
                    help="Typer's data dir (training.jsonl, style.txt). Default: %(default)s")
    ap.add_argument("--corpus", type=Path, default=None,
                    help="optional dir of public-corpus .txt/.jsonl to mix in")
    ap.add_argument("--out", type=Path, default=Path(__file__).parent / "data",
                    help="output dir for sft/kto/dpo jsonl. Default: %(default)s")
    ap.add_argument("--min-ctx-words", type=int, default=4)
    ap.add_argument("--comp-words", type=int, nargs=2, default=(5, 7), metavar=("MIN", "MAX"))
    ap.add_argument("--max-context-chars", type=int, default=600)
    ap.add_argument("--seed", type=int, default=20260617)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    args.out.mkdir(parents=True, exist_ok=True)

    sft: list[dict] = []
    kto: list[dict] = []
    calib: list[dict] = []   # {confidence, good} for recalibrating the runtime gate
    # context -> {"chosen": set, "rejected": set} for DPO pairing
    by_context: dict[tuple[str, str], dict[str, set]] = defaultdict(lambda: {"chosen": set(), "rejected": set()})
    stats: dict = {"sft": defaultdict(int), "kto": defaultdict(int), "dpo": 0,
                   "calib": defaultdict(int), "by_category": defaultdict(int),
                   "skipped_sensitive": 0, "genuine_positives": 0, "capture_records": 0}
    # Real reward signal — Tab/backtick or long type-through accepts attributed PER MODEL.
    # This is what gates real personalization (KTO): a per-model count vs the threshold.
    pos_by_model: dict[str, int] = defaultdict(int)
    KTO_THRESHOLD = 300   # docs/autocomplete-model.md §5.5: ≥300–500 genuine positives

    # --- 1. Live capture: training.jsonl --------------------------------------
    tlog = args.app_dir / "training.jsonl"
    if tlog.exists():
        for line in tlog.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            ctx = (r.get("context") or "")[-args.max_context_chars:]
            sug = (r.get("suggestion") or "").strip()
            cat = r.get("app_category", "other")
            if not ctx or not sug:
                continue
            if looks_sensitive(ctx) or looks_sensitive(sug):
                stats["skipped_sensitive"] += 1
                continue
            # Stable per-context app-name pick: identical context+category must yield
            # the identical prompt so accepted/rejected suggestions on the same context
            # pair up for DPO (a per-record counter would split them).
            prompt = format_prompt(ctx, cat, zlib.crc32(ctx.encode("utf-8")))
            if not prompt:
                continue
            comp = sug if sug.startswith(" ") else " " + sug
            klass, weight, kept_words = classify(r)
            stats["by_category"][cat] += 1
            stats["capture_records"] += 1
            if klass == "positive":
                stats["genuine_positives"] += 1
                pos_by_model[r.get("model", "unknown")] += 1

            # Confidence-gate calibration set: for every SHOWN suggestion, good = a real
            # accept (Tab/backtick, or a long type-through). This lets a calibration step
            # re-fit the ~0.22 gate per model version on real outcomes.
            if r.get("shown", True):
                good = bool(r.get("accepted")) and (
                    r.get("accept_kind") in (None, "tab", "backtick")
                    or int(r.get("words_accepted") or 0) >= 3)
                calib.append({"confidence": float(r.get("confidence") or 0.0), "good": good})
                stats["calib"]["good" if good else "bad"] += 1

            if klass == "neutral":
                continue  # short type-through: no information — neither reward nor SFT
            label = klass == "positive"
            kto.append({"prompt": prompt, "completion": comp, "label": label, "weight": weight})
            stats["kto"]["positive" if label else "negative"] += 1
            if label:
                kept = (first_words(sug, kept_words) if kept_words else sug) or sug
                sft.append({"prompt": prompt, "completion": " " + kept.lstrip()})
                stats["sft"]["capture"] += 1
            by_context[(prompt, cat)]["chosen" if label else "rejected"].add(sug)

    # --- 2. The user's own writing: style.txt ---------------------------------
    style = args.app_dir / "style.txt"
    if style.exists():
        for i, raw in enumerate(style.read_text(encoding="utf-8", errors="ignore").splitlines()):
            raw = raw.strip()
            if not raw:
                continue
            cat, _, text = raw.partition("\t")
            if not text:
                cat, text = "other", cat  # legacy line without a category tab
            for ex in slice_line(text, cat, i, rng, args.min_ctx_words, tuple(args.comp_words)):
                sft.append(ex)
                stats["sft"]["style"] += 1
                stats["by_category"][cat] += 1

    # --- 3. Public corpora: --corpus ------------------------------------------
    if args.corpus and args.corpus.is_dir():
        for i, (text, cat) in enumerate(iter_corpus_texts(args.corpus)):
            for ex in slice_line(text, cat, i, rng, args.min_ctx_words, tuple(args.comp_words)):
                sft.append(ex)
                stats["sft"]["corpus"] += 1

    # --- DPO pairs: same context with both a kept and a rejected suggestion ----
    dpo: list[dict] = []
    for (prompt, _cat), b in by_context.items():
        for chosen in b["chosen"]:
            for rejected in b["rejected"]:
                if chosen != rejected:
                    dpo.append({"prompt": prompt,
                                "chosen": " " + chosen.lstrip(),
                                "rejected": " " + rejected.lstrip()})
    stats["dpo"] = len(dpo)

    # Dedup SFT (sliding windows overlap heavily) and shuffle.
    seen = set()
    deduped = []
    for ex in sft:
        key = (ex["prompt"], ex["completion"])
        if key not in seen:
            seen.add(key)
            deduped.append(ex)
    sft = deduped
    rng.shuffle(sft)
    rng.shuffle(kto)

    def dump(name: str, rows: list[dict]):
        path = args.out / name
        with path.open("w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        return path

    p_sft = dump("sft.jsonl", sft)
    p_kto = dump("kto.jsonl", kto)
    p_dpo = dump("dpo.jsonl", dpo)
    p_calib = dump("calib.jsonl", calib)
    for k in ("sft", "kto", "calib", "by_category"):
        stats[k] = dict(stats[k])
    (args.out / "stats.json").write_text(json.dumps(stats, indent=2), encoding="utf-8")

    print(f"SFT   {len(sft):>7}  -> {p_sft}")
    print(f"KTO   {len(kto):>7}  -> {p_kto}   ({stats['kto']})")
    print(f"DPO   {len(dpo):>7}  -> {p_dpo}")
    print(f"CALIB {len(calib):>7}  -> {p_calib}   ({stats['calib']})")
    print(f"by category: {stats['by_category']}")

    # --- Data-readiness report -------------------------------------------------
    # Cold-start (general SFT from --corpus + style.txt) needs no reward signal and is
    # always trainable. Real personalization (KTO) needs genuine accepts. Make the gap
    # explicit, per model, so it's obvious whether you're cold-starting or tailoring.
    gp = stats["genuine_positives"]
    print(f"\nDATA READINESS")
    print(f"  capture records ........ {stats['capture_records']}")
    print(f"  genuine positives ...... {gp}   (Tab/backtick or ≥3-word type-through)")
    if pos_by_model:
        for m, c in sorted(pos_by_model.items(), key=lambda kv: -kv[1]):
            print(f"      {c:>5}  {m}")
    sft_ok = len(sft) >= 2000
    print(f"  cold-start SFT ......... {'READY' if sft_ok else 'thin'} "
          f"({len(sft)} pairs from corpus+style+capture)")
    if gp >= KTO_THRESHOLD:
        print(f"  personalization (KTO) .. READY ({gp} ≥ {KTO_THRESHOLD})")
    else:
        print(f"  personalization (KTO) .. NOT YET ({gp}/{KTO_THRESHOLD}) — ship the cold-start"
              f" model and let the router collect real accepts attributed to it first.")
    if not sft_ok:
        print("\n  Cold-start SFT is thin. Pass --corpus DIR (see fetch_corpus.py) so typer-1\n"
              "  learns general inline completion before it ever tailors to one user.",
              file=sys.stderr)
    if not sft and not kto:
        print("\nNo data found. Enable 'Record my typing to train a local model' in the\n"
              "Typer menu and use it for a while, and/or pass --corpus DIR.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
