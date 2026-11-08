#!/bin/bash
# Reference run on whisper.cpp: whisper-cli over a clip dir, same JSONL as
# mlx-eval (decode_seconds includes the per-clip model load, so ignore it).
# usage: whispercpp.sh <ggml model> <lang> <clips dir> <out.jsonl> [whisper-cli args...]
set -euo pipefail
model=$1 lang=$2 clips=$3 out=$4
shift 4
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$out"
for wav in "$clips"/*.wav; do
  id=$(basename "$wav" .wav)
  start=$(python3 -c 'import time; print(time.time())')
  whisper-cli -m "$model" -l "$lang" -nt -np -f "$wav" -otxt -of "$tmp/$id" "$@" >/dev/null 2>&1
  python3 -c 'import json, sys, time
print(json.dumps({"id": sys.argv[1], "hypothesis": open(sys.argv[2]).read().strip(),
  "decode_seconds": time.time() - float(sys.argv[3]), "audio_seconds": 0.0}, ensure_ascii=False))' \
    "$id" "$tmp/$id.txt" "$start" >> "$out"
done
