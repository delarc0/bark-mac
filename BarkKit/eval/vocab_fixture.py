# /// script
# requires-python = ">=3.12"
# dependencies = ["tokenizers==0.23.3"]
# ///
"""Generates vocabulary-encode.json, the Vocabulary.encode parity fixture: a list of strings
and their expected token ids for both tokenizers (KB's and large-v3's), encoded with the HF
tokenizers library.

usage: uv run --script vocab_fixture.py

KB's tokenizer.json carries BPE dropout 0.2 (a training leftover): HF tokenizers samples merges
at encode time and gives random ids, so dropout is nulled before loading. Bark's encode adds no
prefix space either (the engine adds " " itself, like mlx_whisper), so add_prefix_space is off.
With those two, both tokenizers give identical ids for every string (their vocab and merges are
byte-identical); the fixture keeps both so the test proves it on disk.
"""
import json
from pathlib import Path

from tokenizers import Tokenizer

MODELS = Path.home() / "Library/Application Support/Bark/Models"
OUT = Path(__file__).with_name("vocabulary-encode.json")

STRINGS = [
    # Swedish with å ä ö é
    "Räksmörgås på Götgatan i Göteborg",
    "Émile Zola och André Gide läste Söderström",
    "Åsa Hägglund frågade Örjan om lönerna",
    # names
    "Leadfabriken",
    "Erik träffade McDonald och O'Brien hos Tegen",
    "Åke Söderqvist, Bionic och MC-Massan",
    # comma-separated term lists, leading space, the glossary framing
    " Leadfabriken, Tegen, Bionic, CPL, MC-Massan",
    "Glossary: Leadfabriken, Tegen, Bionic",
    # digits
    "Order 4711 levererades 2026-10-16 kl 14:30",
    "COVID-19 och H3N2 slog 3,14 procent",
    "42:a våningen, 1.000 kr",
    # punctuation
    "Hallå! Vad sa du? (Verkligen)... Slut.",
    "Citat 'inom' citat \"och\" parenteser [här]",
    # URLs and mail
    "https://lab37.io/kunder/tegen?ref=hq&tab=anteckningar",
    "Maila erik@lab37.io eller ring 070-123 45 67",
    # emoji
    "Mötet gick bra 😀👍 vi ses på fredag 🎉",
    # mixed case
    "COVID-19 drabbade ALLT och alla",
    "JOHN'S BOOK låg kvar",
    "iPhone och iOS på IKEA",
    # double spaces, tab, newline
    "två  mellanslag  här",
    "tre   och en tab\thär",
    "rad ett\nrad två",
    # contractions and more scripts
    "don't stop believing it's true",
    "NAÏVE straße façade",
    "Ĉao ŝi diris",
    # leading spaces and the empty string
    "  Leadfabriken",
    "",
]


def load(path, drop_prefix_space):
    d = json.loads(path.read_text())
    d["model"]["dropout"] = None
    if drop_prefix_space:
        d["pre_tokenizer"]["add_prefix_space"] = False
    return Tokenizer.from_str(json.dumps(d))


def ids(tokenizer, strings):
    return [tokenizer.encode(s, add_special_tokens=False).ids for s in strings]


def main():
    kb = load(MODELS / "kb-whisper-large-8bit/tokenizer.json", drop_prefix_space=True)
    v3 = load(MODELS / "whisper-large-v3-8bit/tokenizer.json", drop_prefix_space=False)
    swedish, general = ids(kb, STRINGS), ids(v3, STRINGS)
    assert swedish == general, "the tokenizers disagree; vocab/merges no longer identical"
    fixture = {"strings": STRINGS, "expected": {"swedish": swedish, "general": general}}
    OUT.write_text(json.dumps(fixture, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {OUT}: {len(STRINGS)} strings, identical on both tokenizers")


if __name__ == "__main__":
    main()
