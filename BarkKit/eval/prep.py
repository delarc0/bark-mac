# /// script
# requires-python = ">=3.12"
# dependencies = ["pyarrow==26.0.0", "soundfile==0.13.1", "numpy==2.4.4"]
# ///
"""Builds every eval set under <eval dir>/sets/<set>/clips (16 kHz mono WAV),
outside git. A set that already has its clips is left alone."""
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
RATE = 16000

sets = Path(sys.argv[1]) / "sets"


def write_set(name, clips, refs=None):
    out = sets / name
    (out / "clips").mkdir(parents=True, exist_ok=True)
    for clip_id, audio in clips:
        sf.write(out / "clips" / f"{clip_id}.wav", audio.astype(np.float32), RATE, subtype="FLOAT")
    if refs is not None:
        (out / "refs.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in refs))
    (out / "ids.txt").write_text("".join(f"{clip_id}\n" for clip_id, _ in clips))
    print(f"prepared {name}: {len(clips)} clips")


def todo(name):
    return not (sets / name / "ids.txt").exists()


def fleurs(lang):
    rows = pq.read_table(FLEURS / LANGS[lang] / "test/0000.parquet").to_pylist()
    # Several speakers per sentence id; the stable sort keeps the first
    # recording in file order so the selection is reproducible.
    rows.sort(key=lambda r: r["id"])
    picked, seen = [], set()
    for r in rows:
        if r["id"] not in seen:
            seen.add(r["id"])
            picked.append(r)
        if len(picked) == CLIPS:
            break
    clips, refs = [], []
    for r in picked:
        audio, rate = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32")
        assert rate == RATE, f"{lang} {r['id']}: {rate} Hz"
        if audio.ndim == 2:
            audio = audio.mean(axis=1)
        clips.append((str(r["id"]), audio))
        refs.append({"id": str(r["id"]), "reference": r["raw_transcription"]})
    return clips, refs


def frame_rms(audio):
    n = len(audio) // 160
    return np.sqrt((audio[: n * 160].reshape(n, 160) ** 2).mean(axis=1))


def speech_onset(audio):
    # Relative, so the quiet FLEURS en recordings (median peak -34 dBFS) work;
    # FLEURS opens with ~0.4 s of silence, which a plain "first 0.8 s" would keep.
    rms = frame_rms(audio)
    return max(0, int(np.argmax(rms > 0.1 * rms.max())) - 10) * 160


def speech_end(audio, margin=0.3):
    # Push-to-talk releases soon after the last word; FLEURS keeps a median
    # 0.8 s of trailing silence, which would flatter any streaming mechanism.
    rms = frame_rms(audio)
    last = len(rms) - 1 - int(np.argmax((rms > 0.05 * rms.max())[::-1]))
    return min(len(audio), (last + 1) * 160 + int(margin * RATE))


def speech_span(audio, margin=0.3):
    return audio[max(0, speech_onset(audio) + 10 * 160 - int(margin * RATE)) : speech_end(audio, margin)]


def peak_normalised(audio, peak_dbfs=-6.0):
    return audio * (10 ** (peak_dbfs / 20) / np.abs(audio).max())


def noise_set(rng):
    def level(x, rms_dbfs):
        return x * (10 ** (rms_dbfs / 20) / np.sqrt((x**2).mean()))

    def pink(n):
        spectrum = np.fft.rfft(rng.standard_normal(n))
        spectrum /= np.sqrt(np.maximum(np.arange(len(spectrum)), 1))
        return np.fft.irfft(spectrum, n)

    def fan(n):
        t = np.arange(n) / RATE
        hum = sum(np.sin(2 * np.pi * f * t + rng.uniform(0, 6.28)) / k for k, f in enumerate((120, 240, 360), 1))
        rumble = np.convolve(rng.standard_normal(n), np.ones(40) / 40, mode="same")
        return hum + 4 * rumble

    def clicks(n, peak_dbfs):
        x = np.zeros(n)
        burst = rng.standard_normal(160) * np.exp(-np.arange(160) / 25)
        for start in np.cumsum(rng.uniform(0.08, 0.35, size=n // 1000) * RATE).astype(int):
            if start + 160 < n:
                x[start : start + 160] += burst * rng.uniform(0.5, 1.0)
        return x * (10 ** (peak_dbfs / 20) / np.abs(x).max())

    clips = []
    for seconds in (1, 3, 6, 10):
        n = seconds * RATE
        clips.append((f"silence-{seconds}s", np.zeros(n)))
        for db in (-60, -50):
            clips.append((f"roomtone{db}-{seconds}s", level(pink(n), db)))
        for db in (-45, -35):
            clips.append((f"fan{db}-{seconds}s", level(fan(n), db)))
        for db in (-30, -15):
            clips.append((f"keys{db}-{seconds}s", clicks(n, db)))
    return clips


for lang in LANGS:
    names = [f"fleurs-{lang}", f"short08-{lang}", f"short25-{lang}", f"dict-{lang}", f"long-{lang}"]
    names += [f"level{db}-{lang}" for db in (0, 20, 30)]
    if not any(todo(name) for name in names):
        continue
    clips, refs = fleurs(lang)
    if todo(f"fleurs-{lang}"):
        write_set(f"fleurs-{lang}", clips, refs)
    for name, seconds in ((f"short08-{lang}", 0.8), (f"short25-{lang}", 2.5)):
        if todo(name):
            write_set(name, [(i, a[speech_onset(a) :][: int(seconds * RATE)]) for i, a in clips])
    # S1 dictation sets: each clip released 0.3 s after its last word, and runs
    # of 4 consecutive clips joined with 0.6 s of their own silence (30-60 s).
    if todo(f"dict-{lang}"):
        write_set(f"dict-{lang}", [(i, a[: speech_end(a)]) for i, a in clips], refs)
    if todo(f"long-{lang}"):
        groups = [range(k, k + 4) for k in range(0, len(clips), 4)]
        write_set(f"long-{lang}",
                  [(clips[g[0]][0], np.concatenate([speech_span(clips[k][1]) for k in g])) for g in groups],
                  [{"id": clips[g[0]][0], "reference": " ".join(refs[k]["reference"] for k in g)} for g in groups])
    # S3 speech levels: every clip at -6 dBFS peak (a well-gained mic), then
    # 20 and 30 dB quieter for soft voices.
    for db in (0, 20, 30):
        if todo(f"level{db}-{lang}"):
            write_set(f"level{db}-{lang}", [(i, peak_normalised(a) * 10 ** (-db / 20)) for i, a in clips], refs)

if todo("noise"):
    write_set("noise", noise_set(np.random.default_rng(37)))
