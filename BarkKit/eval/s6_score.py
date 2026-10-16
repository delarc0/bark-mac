# /// script
# requires-python = ">=3.12"
# dependencies = ["jiwer==4.0.0", "whisper-normalizer==0.1.15"]
# ///
"""Scores the S6 vocabulary-prompting runs in <eval dir>/s6/results and prints the report.

usage: s6_score.py <eval dir>          (eval dir holds s6/results, s6/prompts and sets)

Per set and condition, with score.py's normaliser: WER (delta vs none), term recall (share of
the clip's own terms in the hypothesis) for none vs own+N, insertions (prompt terms in the
hypothesis but not in the reference, per clip and per 100 prompt terms, every one listed), and
decode p50/p95. On noise any non-empty output counts as an insertion. short08 has no references
of its own; the fleurs references of the same ids stand in.
"""
import json
import statistics
import sys
from pathlib import Path

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

sys.path.insert(0, str(Path(__file__).parent))
from s6_prompts import terms_of

SETS = ["short08-sv", "short08-en", "fleurs-sv", "fleurs-en", "dict-sv", "dict-en", "noise"]


def load(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def normaliser(set_name):
    return EnglishTextNormalizer() if set_name.endswith("-en") else BasicTextNormalizer()


def contains(words, term):
    """term (a word list) as a contiguous run inside words."""
    if not term:
        return False
    return any(words[i:i + len(term)] == term for i in range(len(words) - len(term) + 1))


def percentiles(decode):
    p50 = statistics.median(decode)
    p95 = statistics.quantiles(decode, n=20, method="inclusive")[-1] if len(decode) > 1 else decode[0]
    return p50, p95


def main(eval_dir):
    s6 = eval_dir / "s6"
    refs_by_set = {}
    for name in ("fleurs-sv", "fleurs-en", "dict-sv", "dict-en"):
        refs_file = eval_dir / "sets" / name / "refs.jsonl"
        if refs_file.exists():
            refs_by_set[name] = {r["id"]: r["reference"] for r in load(refs_file)}
    if "fleurs-sv" in refs_by_set:
        refs_by_set["short08-sv"] = refs_by_set["fleurs-sv"]
    if "fleurs-en" in refs_by_set:
        refs_by_set["short08-en"] = refs_by_set["fleurs-en"]

    metrics = {}
    insertions_by_run = {}
    spoken_on_noise = {}
    for result in sorted((s6 / "results").glob("*.jsonl")):
        stem = result.stem
        set_name = next(s for s in SETS if stem.startswith(s + "-"))
        condition, model = stem[len(set_name) + 1:].rsplit("-", 1)
        hyps = load(result)
        norm = normaliser(set_name)
        refs = refs_by_set.get(set_name, {})
        lang = "sv" if model.startswith("swedish") else "en"
        prompt_file = s6 / "prompts" / f"{set_name}-{condition}.json"
        if not prompt_file.exists():
            prompt_file = s6 / "prompts" / f"{set_name}-{condition}-fleurs-{lang}.json"
        prompts = json.loads(prompt_file.read_text()) if prompt_file.exists() else {}

        m = {"n": len(hyps)}
        short = set_name.startswith("short08")
        if refs and hyps and not short:
            m["wer"] = jiwer.wer([norm(refs[h["id"]]) for h in hyps], [norm(h["hypothesis"]) for h in hyps])
        if short:
            m["empty"] = sum(1 for h in hyps if not norm(h["hypothesis"]).split())
        recalled = total = 0
        insertions = []
        prompt_terms = 0
        none_hyps = {}
        none_file = s6 / "results" / f"{set_name}-none-{model}.jsonl"
        if condition != "none" and none_file.exists():
            none_hyps = {h["id"]: h["hypothesis"] for h in load(none_file)}
        for h in hyps:
            own = terms_of(refs.get(h["id"], ""))
            hyp_words = norm(h["hypothesis"]).split()
            ref_words = norm(refs.get(h["id"], "")).split()
            if own and not short:
                recalled += sum(1 for t in own if contains(hyp_words, norm(t).split()))
                total += len(own)
            prompt = h.get("prompt") or prompts.get(h["id"], "")
            terms = [t for t in prompt.removeprefix("Glossary: ").split(", ") if t]
            prompt_terms += len(terms)
            none_words = norm(none_hyps.get(h["id"], "")).split()
            for term in terms:
                term_words = norm(term).split()
                if contains(hyp_words, term_words) and not contains(ref_words, term_words):
                    # The FLEURS references are abridged, so a term the unprompted run also
                    # writes is not the prompt's doing; count those apart from the rest.
                    insertions.append((h["id"], term, "also unprompted" if contains(none_words, term_words) else "prompt-caused"))
        if total:
            m["recall"] = (recalled, total)
        m["insertions"] = len(insertions)
        m["insertions_caused"] = sum(1 for _, _, kind in insertions if kind == "prompt-caused")
        m["prompt_terms"] = prompt_terms
        m["p50"], m["p95"] = percentiles(sorted(h["decode_seconds"] for h in hyps))
        if set_name == "noise":
            spoken_on_noise[(set_name, condition, model)] = [(h["id"], h["hypothesis"]) for h in hyps if norm(h["hypothesis"]).split()]
            m["non_empty"] = len(spoken_on_noise[(set_name, condition, model)])
        insertions_by_run[(set_name, condition, model)] = insertions
        metrics[(set_name, condition, model)] = m

    pairs = sorted({(s, m) for s, _, m in metrics})
    order = ["none", "own+40", "own+40-glossary", "own+150", "40", "none-last"]
    conditions = [c for c in order if any(key[1] == c for key in metrics)]
    conditions += sorted({key[1] for key in metrics} - set(conditions))
    for set_name, model in pairs:
        base = metrics.get((set_name, "none", model)) or metrics.get((set_name, "none-last", model))
        header = f"### {set_name} on {model}"
        rows = [f"| condition | WER | delta | term recall | insertions | per 100 terms | decode p50 | p95 |",
                "|---|---|---|---|---|---|---|---|"]
        for condition in conditions:
            m = metrics.get((set_name, condition, model))
            if m is None:
                continue
            wer = f"{m['wer']:.2%}" if "wer" in m else "-"
            delta = f"{(m['wer'] - base['wer']) * 100:+.2f}" if "wer" in m and base and "wer" in base else "-"
            recall = f"{m['recall'][0]}/{m['recall'][1]} ({m['recall'][0] / m['recall'][1]:.0%})" if "recall" in m else "-"
            ins = m["insertions"]
            ins_text = f"{m['insertions_caused']}/{ins}" if ins else "0"
            rate = f"{m['insertions_caused'] / m['prompt_terms'] * 100:.2f}" if m["prompt_terms"] else "-"
            extra = f" ({m['non_empty']} non-empty)" if set_name == "noise" else ""
            extra += f" ({m['empty']} empty)" if "empty" in m else ""
            rows.append(f"| {condition} | {wer} | {delta} | {recall} | {ins_text}{extra} | {rate} | {m['p50']:.2f} | {m['p95']:.2f} |")
        print(header)
        print("\n".join(rows))
        print()
    print("### Insertions (clip: term)")
    any_insertions = False
    for key, insertions in sorted(insertions_by_run.items()):
        if not insertions:
            continue
        any_insertions = True
        set_name, condition, model = key
        print(f"{set_name} / {condition} / {model}:")
        for clip, term, kind in insertions:
            print(f"  {clip}: {term} ({kind})")
    if not any_insertions:
        print("none")
    for key, spoken in sorted(spoken_on_noise.items()):
        if not spoken:
            continue
        set_name, condition, model = key
        print(f"\n### Noise, non-empty outputs ({set_name} / {condition} / {model})")
        for clip, text in spoken:
            print(f"  {clip}: {text}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
