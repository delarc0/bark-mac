# /// script
# requires-python = ">=3.12"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""Scores results/<lang>-<model>.jsonl against fleurs/<lang>/refs.jsonl."""
import json
import statistics
import sys
from pathlib import Path

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

NORMALIZERS = {"en": EnglishTextNormalizer(), "sv": BasicTextNormalizer()}


def load(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def p90(values):
    return statistics.quantiles(values, n=10, method="inclusive")[-1]


root = Path(sys.argv[1])
print(f"{'clips':5} {'model':8} {'n':>3} {'WER':>7} {'median s':>9} {'p90 s':>7} {'RTF':>6}")
for result in sorted((root / "results").glob("*.jsonl")):
    lang, model = result.stem.split("-", 1)
    refs = {r["id"]: r["reference"] for r in load(root / "fleurs" / lang / "refs.jsonl")}
    hyps = load(result)
    assert sorted(h["id"] for h in hyps) == sorted(refs), f"{result.name}: clip ids differ from refs"
    norm = NORMALIZERS[lang]
    wer = jiwer.wer([norm(refs[h["id"]]) for h in hyps], [norm(h["hypothesis"]) for h in hyps])
    decode = [h["decode_seconds"] for h in hyps]
    rtf = sum(decode) / sum(h["audio_seconds"] for h in hyps)
    print(f"{lang:5} {model:8} {len(hyps):>3} {wer:>7.2%} {statistics.median(decode):>9.2f} {p90(decode):>7.2f} {rtf:>6.3f}")
