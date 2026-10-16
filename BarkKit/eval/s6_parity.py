# /// script
# requires-python = ">=3.12"
# dependencies = ["mlx-whisper==0.4.3"]
# ///
"""S6 parity: mlx_whisper 0.4.3's initial_prompt against the Swift engine's prompt path.

usage: uv run --script s6_parity.py --model <local model folder> --language <code>
       --clips <dir> --prompts <file.json> --out <file.json>

Decodes every .wav in <dir> with the prompt <file.json> assigns its id (unprompted when
absent), exactly as the engine is run: forced language, transcribe, without_timestamps,
condition_on_previous_text=False, temperature=0. Output: one {"id", "text"} JSON line per clip.
"""
import argparse
import json
from pathlib import Path

import mlx_whisper


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--language", required=True)
    parser.add_argument("--clips", required=True, type=Path)
    parser.add_argument("--prompts", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    prompts = json.loads(args.prompts.read_text())
    args.out.write_text("")
    with args.out.open("a") as out:
        for clip in sorted(args.clips.glob("*.wav")):
            result = mlx_whisper.transcribe(
                str(clip),
                path_or_hf_repo=args.model,
                language=args.language,
                initial_prompt=prompts.get(clip.stem),
                condition_on_previous_text=False,
                without_timestamps=True,
                temperature=0,
                verbose=False,
            )
            out.write(json.dumps({"id": clip.stem, "text": result["text"].strip()}, ensure_ascii=False) + "\n")
            out.flush()
            print(clip.stem, flush=True)


if __name__ == "__main__":
    main()
