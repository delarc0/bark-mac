# /// script
# requires-python = ">=3.12"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""Scores spike S1: <eval dir>/s1/results/<set>-<mechanism>.jsonl."""
import statistics
import sys
from pathlib import Path

import jiwer

from score import load, metrics, normaliser


def seams(norm, parts):
    """Duplicated words across a seam, and parts opening with 3+ words copied from the prompt."""
    words = [norm(p).split() for p in parts]
    duplicated = leaked = 0
    for i in range(1, len(words)):
        before, after = words[i - 1], words[i]
        duplicated += max((k for k in range(1, 4) if before[-k:] == after[:k] and len(after) >= k), default=0)
        prompt = " ".join(w for part in words[:i] for w in part)
        leaked += len(after) >= 3 and " ".join(after[:3]) in prompt
    return duplicated, leaked


eval_dir = Path(sys.argv[1])
s1 = eval_dir / "s1"
print(f"{'set':8} {'mechanism':11} {'n':>3} {'WER':>7} {'empty':>5} {'r2f p50':>7} {'r2f p95':>7} "
      f"{'busy/aud':>8} {'cpu/aud':>7} {'parts':>5} {'dup':>4} {'leak':>4} {'del':>4} {'ins':>4}")
for result in sorted(s1.glob("results/*.jsonl")):
    kind, lang, mechanism = result.stem.split("-", 2)
    set_name = f"{kind}-{lang}"
    refs = {r["id"]: r["reference"] for r in load(eval_dir / "sets" / set_name / "refs.jsonl")}
    hyps = load(result)
    norm = normaliser(set_name)
    m = metrics(set_name, hyps, refs)
    r2f = sorted(h["release_to_final"] for h in hyps)
    p95 = statistics.quantiles(r2f, n=20, method="inclusive")[-1]
    audio = sum(h["audio_seconds"] for h in hyps)
    dup = leak = 0
    for h in hyps:
        d, l = seams(norm, h["parts"])
        dup, leak = dup + d, leak + l
    out = jiwer.process_words([norm(refs[h["id"]]) for h in hyps], [norm(h["hypothesis"]) for h in hyps])
    print(f"{set_name:8} {mechanism:11} {len(hyps):>3} {m['wer']:>7.2%} {m['empty']:>5} {statistics.median(r2f):>7.2f} "
          f"{p95:>7.2f} {sum(h['decoder_busy'] for h in hyps) / audio:>8.3f} {sum(h['cpu_seconds'] for h in hyps) / audio:>7.3f} "
          f"{sum(len(h['parts']) for h in hyps):>5} {dup:>4} {leak:>4} {out.deletions:>4} {out.insertions:>4}")
