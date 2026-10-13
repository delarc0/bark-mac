# /// script
# requires-python = ">=3.12"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""Scores <eval dir>/results/<set>-<model>.jsonl and gates against baseline.json.

usage: score.py <eval dir> [--baseline <file>] [--write-baseline | --table-only]

--baseline gates against (or with --write-baseline writes) another file, e.g.
baseline-mlx.json for the MLX pipeline. Pipeline rows add release-to-final p50/p95
and, for --language auto runs (model "auto"), the clips routed to KB; a set whose
baseline routes none to KB fails on any.

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


def metrics(set_name, hyps, refs=None, routed=False):
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
    if hyps and all("release_to_final" in h for h in hyps):
        r2f = sorted(h["release_to_final"] for h in hyps)
        m["r2f_p50"] = statistics.median(r2f)
        m["r2f_p95"] = statistics.quantiles(r2f, n=20, method="inclusive")[-1] if len(r2f) > 1 else r2f[0]
    if routed:
        m["kb_routes"] = sum(1 for h in hyps if h.get("model") == "swedish")
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
        if base.get("kb_routes") == 0 and cur.get("kb_routes", 0) > 0:
            found.append(f"{key}: {cur['kb_routes']} clips routed to KB")
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
        current[f"{set_name}/{model}"] = metrics(set_name, hyps, refs, routed=model.startswith("auto"))
    return current


def table(current):
    lines = [f"{'set/model':22} {'n':>3} {'WER':>7} {'empty':>5} {'halluc':>6} {'median s':>8} {'p90 s':>6} {'RTF':>6}"
             f" {'r2f p50':>7} {'r2f p95':>7} {'to KB':>5}"]
    for key, m in current.items():
        wer = f"{m['wer']:.2%}" if "wer" in m else "-"
        hal = str(m["hallucinated_words"]) if "hallucinated_words" in m else "-"
        r2f = f"{m['r2f_p50']:>7.2f} {m['r2f_p95']:>7.2f}" if "r2f_p50" in m else f"{'-':>7} {'-':>7}"
        lines.append(f"{key:22} {m['n']:>3} {wer:>7} {m['empty']:>5} {hal:>6} "
                     f"{m.get('decode_median', 0):>8.2f} {m.get('decode_p90', 0):>6.2f} {m.get('rtf', 0):>6.3f}"
                     f" {r2f} {m.get('kb_routes', '-'):>5}")
    return "\n".join(lines)


def self_test():
    base = {"a/m": {"n": 2, "empty": 0, "wer": 0.05}, "noise/m": {"n": 2, "empty": 2, "hallucinated_words": 0}}
    assert regressions(base, {"a/m": {"n": 2, "empty": 0, "wer": 0.052}, "noise/m": {"n": 2, "empty": 2, "hallucinated_words": 0}}) == []
    assert len(regressions(base, {"a/m": {"n": 2, "empty": 1, "wer": 0.054}, "noise/m": {"n": 2, "empty": 1, "hallucinated_words": 3}})) == 3
    assert regressions(base, {}) == ["a/m: no result", "noise/m: no result"]
    assert regressions({"noise/m": {"n": 1, "empty": 0, "hallucinated_words": 9}}, {"noise/m": {"n": 1, "empty": 0, "hallucinated_words": 12}}) == []
    assert regressions({"a/auto": {"n": 1, "empty": 0, "kb_routes": 0}}, {"a/auto": {"n": 1, "empty": 0, "kb_routes": 1}}) == ["a/auto: 1 clips routed to KB"]
    rows = [{"hypothesis": "a", "decode_seconds": 1, "audio_seconds": 1, "release_to_final": t, "model": "swedish"} for t in (1, 2, 3)]
    m = metrics("x-sv", rows, routed=True)
    assert (m["r2f_p50"], m["kb_routes"]) == (2, 3)


if __name__ == "__main__":
    self_test()
    if "--baseline" in sys.argv:
        BASELINE = Path(sys.argv[sys.argv.index("--baseline") + 1])
    current = score(Path(sys.argv[1]))
    print(table(current))
    if "--table-only" in sys.argv:
        sys.exit(0)
    if "--write-baseline" in sys.argv:
        BASELINE.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        print(f"wrote {BASELINE}")
        sys.exit(0)
    found = regressions(json.loads(BASELINE.read_text()), current) if BASELINE.exists() else ["no baseline.json"]
    for line in found:
        print(f"REGRESSION {line}")
    sys.exit(1 if found else 0)
