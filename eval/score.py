#!/usr/bin/env python3
"""Scores speech-recognition output against the eval manifest.

Usage: score.py <results.jsonl> [<results.jsonl> ...] [--show CATEGORY] [--limit N]

Each results file has one JSON object per line with at least: id, hypothesis.
Reference text and category come from eval/data/manifest.jsonl.
Reports corpus-level WER and CER per category, plus how many English (Latin-script)
reference words survive in Latin script in the hypothesis.
"""
import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

MANIFEST = Path(__file__).parent / "data" / "manifest.jsonl"

ARABIC_DIACRITICS = re.compile(r"[ً-ٰٟۖ-ۭـ]")
ARABIC_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩", "0123456789")


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text or "").lower()
    text = ARABIC_DIACRITICS.sub("", text)
    text = text.translate(ARABIC_DIGITS)
    text = re.sub("[إأآٱ]", "ا", text)
    text = text.replace("ى", "ي").replace("ة", "ه").replace("ؤ", "و").replace("ئ", "ي")
    # Drop anything that is not a letter, digit or space (covers Arabic and Latin punctuation).
    text = "".join(ch if (ch.isalnum() or ch.isspace()) else " " for ch in text)
    return re.sub(r"\s+", " ", text).strip()


def edit_distance(a, b) -> int:
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def is_latin_word(word: str) -> bool:
    return bool(re.fullmatch(r"[a-z][a-z'’-]*", word)) and len(word) > 1


def load_manifest():
    items = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if line.strip():
            item = json.loads(line)
            items[item["id"]] = item
    return items


def score(path: Path, manifest, show=None, limit=8):
    totals = defaultdict(lambda: defaultdict(float))
    shown = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        item = manifest.get(row.get("id"))
        if item is None:
            continue
        category = item["category"]
        reference = normalize(item.get("reference", ""))
        hypothesis = normalize(row.get("hypothesis", ""))
        ref_words, hyp_words = reference.split(), hypothesis.split()
        bucket = totals[category]
        bucket["clips"] += 1
        bucket["audio_s"] += float(row.get("audio_s") or item.get("duration_s") or 0)
        bucket["ms"] += float(row.get("total_ms") or 0)
        if not ref_words:
            # Silence clips: any output at all is a hallucination.
            bucket["hallucinated"] += 1 if hyp_words else 0
            if show == category and shown < limit:
                print(f"  [{row['id']}] HYP: {row.get('hypothesis', '')!r}")
                shown += 1
            continue
        bucket["word_errors"] += edit_distance(ref_words, hyp_words)
        bucket["ref_words"] += len(ref_words)
        ref_chars, hyp_chars = reference.replace(" ", ""), hypothesis.replace(" ", "")
        bucket["char_errors"] += edit_distance(ref_chars, hyp_chars)
        bucket["ref_chars"] += len(ref_chars)
        latin = [w for w in ref_words if is_latin_word(w)]
        if category != "english" and latin:
            hyp_set = set(hyp_words)
            bucket["latin_ref"] += len(latin)
            bucket["latin_kept"] += sum(1 for w in latin if w in hyp_set)
        if show == category and shown < limit:
            print(f"  [{row['id']}]\n    REF: {item.get('reference', '')}\n    HYP: {row.get('hypothesis', '')}")
            shown += 1
    return totals


def main():
    args = sys.argv[1:]
    show = None
    limit = 8
    paths = []
    index = 0
    while index < len(args):
        if args[index] == "--show":
            show = args[index + 1]
            index += 2
        elif args[index] == "--limit":
            limit = int(args[index + 1])
            index += 2
        else:
            paths.append(Path(args[index]))
            index += 1
    manifest = load_manifest()
    order = ["levantine", "codeswitch", "egyptian", "gulf", "msa", "english", "silence"]
    for path in paths:
        print(f"\n=== {path.stem} ===")
        totals = score(path, manifest, show, limit)
        print(f"{'category':<11}{'clips':>6}{'WER%':>8}{'CER%':>8}{'latin kept':>12}{'ms/clip':>9}{'x realtime':>11}")
        all_we = all_rw = all_ce = all_rc = 0.0
        for category in order + sorted(set(totals) - set(order)):
            if category not in totals:
                continue
            b = totals[category]
            clips = int(b["clips"])
            ms = b["ms"] / clips if clips else 0
            rtf = (b["audio_s"] * 1000 / b["ms"]) if b["ms"] else 0
            if b["ref_words"] == 0:
                print(f"{category:<11}{clips:>6}{'':>8}{'':>8}{'':>12}{ms:>9.0f}{rtf:>11.0f}   hallucinated on {int(b['hallucinated'])}/{clips}")
                continue
            wer = 100 * b["word_errors"] / b["ref_words"]
            cer = 100 * b["char_errors"] / b["ref_chars"]
            kept = f"{int(b['latin_kept'])}/{int(b['latin_ref'])}" if b["latin_ref"] else "-"
            print(f"{category:<11}{clips:>6}{wer:>8.1f}{cer:>8.1f}{kept:>12}{ms:>9.0f}{rtf:>11.0f}")
            if category != "silence":
                all_we += b["word_errors"]; all_rw += b["ref_words"]; all_ce += b["char_errors"]; all_rc += b["ref_chars"]
        if all_rw:
            print(f"{'ALL':<11}{'':>6}{100 * all_we / all_rw:>8.1f}{100 * all_ce / all_rc:>8.1f}")


if __name__ == "__main__":
    main()
