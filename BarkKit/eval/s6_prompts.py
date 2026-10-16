"""Builds the S6 prompt files for mlx-eval --prompts: one JSON per set and condition,
clip id to prompt string (a clip absent from the map decodes unprompted). Stdlib only.

usage: s6_prompts.py --sets <eval sets dir> --out <dir>
                     [--set fleurs-sv] [--pool-set <set the term pool comes from>] [--conditions a,b]

A clip's terms are the words in its reference that are capitalised and not sentence-initial,
plus hyphenated or digit-bearing tokens ("COVID-19"); the pool is deduplicated per set.
Conditions:
  none              no prompts (an empty map, for the record)
  own+40            the clip's own terms plus 40 drawn (seeded) from other clips, shuffled
  40                40 terms from other clips only, none occurring in this clip's reference
  own+40-glossary   own+40 prefixed "Glossary: "
  own+150           own terms plus 150 others (size sensitivity)
noise has no references: its "40" prompts are drawn from --pool-set's pool.
"""
import argparse
import json
import random
import re
import zlib
from pathlib import Path

STRIP = "\"'“”‘’.,;:!?…()[]{}<>«»"
SENTENCE_END = (".", "!", "?", "…")


def words(reference):
    return reference.split()


def terms_of(reference):
    """A clip's own terms, deduplicated, in reference order."""
    raw = words(reference)
    out = []
    for i, token in enumerate(raw):
        word = token.strip(STRIP)
        if not any(c.isalnum() for c in word):
            continue
        previous = raw[i - 1].strip(STRIP) if i else ""
        sentence_initial = i == 0 or previous.endswith(SENTENCE_END)
        if (word[0].isupper() and not sentence_initial) or "-" in word or any(c.isdigit() for c in word):
            if word not in out:
                out.append(word)
    return out


def load_set(sets, name):
    refs_file = sets / name / "refs.jsonl"
    refs = {}
    if refs_file.exists():
        refs = {json.loads(line)["id"]: json.loads(line)["reference"] for line in refs_file.read_text().splitlines() if line.strip()}
    ids = (sets / name / "ids.txt").read_text().split()
    return ids, refs


def reference_words(reference):
    return {w.strip(STRIP).lower() for w in words(reference) if w.strip(STRIP)}


def build(sets, name, pool_name, condition):
    ids, refs = load_set(sets, name)
    pool_ids, pool_refs = load_set(sets, pool_name)
    own = {i: terms_of(r) for i, r in refs.items()}
    pool = []
    for i in pool_ids:
        for term in terms_of(pool_refs.get(i, "")):
            if term not in pool:
                pool.append(term)
    prompts = {}
    for clip in ids:
        # The glossary variant reuses the base condition's draw, so only the framing differs.
        rng = random.Random(zlib.crc32(f"{name}:{condition.removesuffix('-glossary')}:{clip}".encode()))
        own_terms = own.get(clip, [])
        others = [t for t in pool if t not in own_terms]
        if condition.startswith("own+"):
            base = condition.removeprefix("own+").removesuffix("-glossary")
            n = int(base)
            drawn = rng.sample(others, min(n, len(others)))
            terms = own_terms + drawn
            rng.shuffle(terms)
            text = ", ".join(terms)
            if condition.endswith("-glossary"):
                text = "Glossary: " + text
            prompts[clip] = text
        elif condition == "40":
            allowed = [t for t in others if t.lower() not in reference_words(refs.get(clip, ""))]
            drawn = rng.sample(allowed, min(40, len(allowed)))
            rng.shuffle(drawn)
            prompts[clip] = ", ".join(drawn)
    return prompts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sets", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--set", dest="only")
    parser.add_argument("--pool-set", dest="pool")
    parser.add_argument("--conditions", default="own+40,40,own+40-glossary,own+150")
    args = parser.parse_args()

    runs = [
        # set, pool set, conditions
        ("fleurs-sv", None, "own+40,40,own+40-glossary,own+150"),
        ("dict-sv", None, "own+40,40"),
        ("fleurs-en", None, "own+40,40,own+40-glossary"),
        ("dict-en", None, "own+40,40"),
        ("noise", "fleurs-sv", "40"),
        ("noise", "fleurs-en", "40"),
        ("short08-sv", "fleurs-sv", "40"),
        ("short08-en", "fleurs-en", "40"),
    ]
    args.out.mkdir(parents=True, exist_ok=True)
    for name, pool, conditions in runs:
        if args.only and name != args.only:
            continue
        if args.pool and pool != args.pool:
            continue
        if args.conditions:
            conditions = ",".join(c for c in conditions.split(",") if c in args.conditions.split(","))
        for condition in conditions.split(","):
            prompts = build(args.sets, name, pool or name, condition)
            suffix = f"-{pool}" if pool else ""
            out = args.out / f"{name}-{condition}{suffix}.json"
            out.write_text(json.dumps(prompts, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
            counts = [len(p.split(", ")) for p in prompts.values()]
            print(f"{out.name}: {len(prompts)} clips, {min(counts)}-{max(counts)} terms per prompt")


if __name__ == "__main__":
    main()
