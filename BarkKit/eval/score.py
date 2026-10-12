# /// script
# requires-python = ">=3.12"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""Scores <eval dir>/results/<set>-<model>.jsonl and gates against baseline.json.

usage: score.py <eval dir> [--write-baseline]

Exit 1 on: a missing or resized run, WER up 0.3 points absolute, more empty
results, or hallucinated words on a set whose baseline has none. Engine-only
noise runs have no speech gate in front of the decoder, so their nonzero
hallucination counts are recorded and shown but cannot gate (fallback sampling
makes the count random); the pipeline-mode noise baseline will be 0.
"""
import json
import statistics
import sys
from pathlib import Path

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

BASELINE = Path(__file__).with_name("baseline.json")
WER_SLACK = 0.003


def normaliser(set_name):
    return EnglishTextNormalizer() if set_name.endswith("-en") else BasicTextNormalizer()


def load(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def metrics(set_name, hyps, refs=None):
    """refs: id -> reference text for WER sets; hyps may be a subset of refs."""
    norm = normaliser(set_name)
    m = {"n": len(hyps), "empty": sum(1 for h in hyps if not norm(h["hypothesis"]).split())}
    if refs is not None:
        assert {h["id"] for h in hyps} <= set(refs), f"{set_name}: hypotheses outside the reference set"
        if hyps:
            m["wer"] = jiwer.wer([norm(refs[h["id"]]) for h in hyps], [norm(h["hypothesis"]) for h in hyps])
    if set_name == "noise":
        m["hallucinated_words"] = sum(len(norm(h["hypothesis"]).split()) for h in hyps)
    decode = [h["decode_seconds"] for h in hyps]
    audio = sum(h["audio_seconds"] for h in hyps)
    if len(decode) > 1:
        m["decode_median"] = statistics.median(decode)
        m["decode_p90"] = statistics.quantiles(decode, n=10, method="inclusive")[-1]
    if audio:
        m["rtf"] = sum(decode) / audio
    return m


def regressions(baseline, current):
    found = []
    for key, base in baseline.items():
        cur = current.get(key)
        if cur is None:
            found.append(f"{key}: no result")
            continue
        if cur["n"] != base["n"]:
            found.append(f"{key}: {cur['n']} clips, baseline {base['n']}")
        if "wer" in base and cur.get("wer", 1.0) > base["wer"] + WER_SLACK:
            found.append(f"{key}: WER {cur.get('wer', 1.0):.2%} vs baseline {base['wer']:.2%}")
        if cur["empty"] > base["empty"]:
            found.append(f"{key}: {cur['empty']} empty results, baseline {base['empty']}")
        if base.get("hallucinated_words") == 0 and cur.get("hallucinated_words", 0) > 0:
            found.append(f"{key}: {cur['hallucinated_words']} hallucinated words")
    return found


def score(eval_dir):
    current = {}
    for result in sorted((eval_dir / "results").glob("*.jsonl")):
        set_name, model = result.stem.rsplit("-", 1)
        refs_file = eval_dir / "sets" / set_name / "refs.jsonl"
        refs = {r["id"]: r["reference"] for r in load(refs_file)} if refs_file.exists() else None
        hyps = load(result)
        ids = (eval_dir / "sets" / set_name / "ids.txt").read_text().split()
        assert sorted(h["id"] for h in hyps) == sorted(ids), f"{result.name}: clip ids differ from the set"
        current[f"{set_name}/{model}"] = metrics(set_name, hyps, refs)
    return current


def table(current):
    lines = [f"{'set/model':22} {'n':>3} {'WER':>7} {'empty':>5} {'halluc':>6} {'median s':>8} {'p90 s':>6} {'RTF':>6}"]
    for key, m in current.items():
        wer = f"{m['wer']:.2%}" if "wer" in m else "-"
        hal = str(m["hallucinated_words"]) if "hallucinated_words" in m else "-"
        lines.append(f"{key:22} {m['n']:>3} {wer:>7} {m['empty']:>5} {hal:>6} "
                     f"{m.get('decode_median', 0):>8.2f} {m.get('decode_p90', 0):>6.2f} {m.get('rtf', 0):>6.3f}")
    return "\n".join(lines)


def self_test():
    base = {"a/m": {"n": 2, "empty": 0, "wer": 0.05}, "noise/m": {"n": 2, "empty": 2, "hallucinated_words": 0}}
    assert regressions(base, {"a/m": {"n": 2, "empty": 0, "wer": 0.052}, "noise/m": {"n": 2, "empty": 2, "hallucinated_words": 0}}) == []
    assert len(regressions(base, {"a/m": {"n": 2, "empty": 1, "wer": 0.054}, "noise/m": {"n": 2, "empty": 1, "hallucinated_words": 3}})) == 3
    assert regressions(base, {}) == ["a/m: no result", "noise/m: no result"]
    assert regressions({"noise/m": {"n": 1, "empty": 0, "hallucinated_words": 9}}, {"noise/m": {"n": 1, "empty": 0, "hallucinated_words": 12}}) == []


if __name__ == "__main__":
    self_test()
    current = score(Path(sys.argv[1]))
    print(table(current))
    if "--write-baseline" in sys.argv:
        BASELINE.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        print(f"wrote {BASELINE}")
        sys.exit(0)
    found = regressions(json.loads(BASELINE.read_text()), current) if BASELINE.exists() else ["no baseline.json"]
    for line in found:
        print(f"REGRESSION {line}")
    sys.exit(1 if found else 0)
