# /// script
# requires-python = ">=3.12"
# dependencies = ["pyarrow==26.0.0", "soundfile==0.13.1", "numpy==2.4.4"]
# ///
"""Exports the first 60 FLEURS test clips per language (sorted by id, one
recording per id) as 16 kHz mono WAV plus references, outside git."""
import io
import json
import sys
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

FLEURS = Path.home() / ".cache/huggingface/hub/datasets--google--fleurs/snapshots/168de341b3db6859a9bac1c50a2ef5e3b47647e0"
LANGS = {"sv": "sv_se", "en": "en_us"}
CLIPS = 60

out_root = Path(sys.argv[1]) / "fleurs"
for lang, config in LANGS.items():
    out = out_root / lang
    if (out / "refs.jsonl").exists():
        continue
    rows = pq.read_table(FLEURS / config / "test/0000.parquet").to_pylist()
    # FLEURS has several speakers per sentence id; the stable sort keeps the
    # first recording in file order so the selection is reproducible.
    rows.sort(key=lambda r: r["id"])
    picked, seen = [], set()
    for r in rows:
        if r["id"] not in seen:
            seen.add(r["id"])
            picked.append(r)
        if len(picked) == CLIPS:
            break
    (out / "clips").mkdir(parents=True, exist_ok=True)
    refs = []
    for r in picked:
        audio, rate = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32")
        assert rate == 16000, f"{lang} {r['id']}: {rate} Hz"
        if audio.ndim == 2:
            audio = audio.mean(axis=1)
        sf.write(out / "clips" / f"{r['id']}.wav", audio.astype(np.float32), 16000, subtype="FLOAT")
        refs.append({"id": str(r["id"]), "reference": r["raw_transcription"]})
    (out / "refs.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in refs))
    (out / "ids.txt").write_text("".join(x["id"] + "\n" for x in refs))
    print(f"prepared {len(refs)} {lang} clips in {out}")
