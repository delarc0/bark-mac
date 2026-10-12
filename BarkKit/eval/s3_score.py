# /// script
# requires-python = ">=3.12"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""Scores spike S3 runs: <eval dir>/s3/results/<set>@<gate>-<model>.jsonl."""
import json
import sys
from pathlib import Path

from score import load, metrics

eval_dir = Path(sys.argv[1])
s3 = eval_dir / "s3"
print(f"{'set':10} {'gate':9} {'model':8} {'clips':>5} {'rejected':>8} {'kept s':>7} {'WER pass':>8} {'halluc':>6}")
for result in sorted((s3 / "results").glob("*.jsonl")):
    head, model = result.stem.rsplit("-", 1)
    set_name, gate = head.split("@")
    ids = (eval_dir / "sets" / set_name / "ids.txt").read_text().split()
    refs_file = eval_dir / "sets" / set_name / "refs.jsonl"
    refs = {r["id"]: r["reference"] for r in load(refs_file)} if refs_file.exists() else None
    hyps = load(result)
    if gate == "none":
        passed, kept = len(ids), "-"
    else:
        decisions = load(s3 / "gated" / f"{set_name}@{gate}" / "gate.jsonl")
        assert sorted(d["id"] for d in decisions) == sorted(ids), f"{result.name}: gate saw other clips"
        passed = sum(d["passed"] for d in decisions)
        kept = f"{sum(d['kept_seconds'] for d in decisions):.1f}"
    assert len(hyps) == passed, f"{result.name}: {len(hyps)} decodes for {passed} passed clips"
    m = metrics(set_name, hyps, refs)
    wer = f"{m['wer']:.2%}" if "wer" in m else "-"
    hal = str(m.get("hallucinated_words", "-"))
    print(f"{set_name:10} {gate:9} {model:8} {len(ids):>5} {len(ids) - passed:>8} {kept:>7} {wer:>8} {hal:>6}")
