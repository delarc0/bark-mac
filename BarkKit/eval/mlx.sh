#!/bin/bash
# Spike S8: run.sh's matrix on the Swift MLX engine (mlx-eval), scored against the CoreML baseline.
# usage: mlx.sh [extra model]   e.g. mlx.sh swedish8 also runs fleurs-sv on the 8-bit KB build
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
out="$eval_dir/mlx"
mkdir -p "$out/results" "$out/sets"

# mlx-swift's README says SwiftPM cannot build the Metal shaders; with Xcode 26's SwiftPM it does
# (mlx-swift_Cmlx.bundle/default.metallib lands next to the binary). If a toolchain ever regresses
# ("Failed to load the default metallib"), build with:
#   xcodebuild build -scheme mlx-eval -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath .build/xcode
swift build -c release --package-path "$here/.." --product mlx-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)/mlx-eval"

# shortcut: mlx-eval decodes one 30 s window, so a set with longer clips (fleurs-sv: 1716, 31.4 s)
# is scored without them through a filtered copy; drop this when the engine gets a seek loop.
sets="fleurs-sv fleurs-en short08-sv short25-sv short08-en short25-en noise"
for set in $sets; do
  src="$eval_dir/sets/$set"
  dst="$out/sets/$set"
  rm -rf "$dst"
  long="$(for f in "$src"/clips/*.wav; do
    afinfo "$f" | awk -v id="$(basename "$f" .wav)" '/estimated duration/ && $3 > 30 { print id }'
  done)"
  if [ -z "$long" ]; then
    ln -s "../../sets/$set" "$dst"
    continue
  fi
  echo "$set: skipping clips over 30 s: $long"
  mkdir -p "$dst/clips"
  grep -vxF "$long" "$src/ids.txt" > "$dst/ids.txt"
  [ -f "$src/refs.jsonl" ] && ln -s "$src/refs.jsonl" "$dst/refs.jsonl"
  while read -r id; do ln -s "$src/clips/$id.wav" "$dst/clips/$id.wav"; done < "$dst/ids.txt"
done

runs=("fleurs-sv swedish sv" "fleurs-sv general sv"
  "fleurs-en general en" "fleurs-en swedish en"
  "short08-sv swedish sv" "short25-sv swedish sv"
  "short08-en general en" "short25-en general en"
  "noise swedish sv" "noise general en")
[ $# -gt 0 ] && runs+=("fleurs-sv $1 sv")
for run in "${runs[@]}"; do
  set -- $run
  echo "== $1 on $2 ($3) =="
  "$bin" --model "$2" --language "$3" \
    --clips "$out/sets/$1/clips" --out "$out/results/$1-$2.jsonl" 2> >(grep -v '^\[mlx-eval\] [0-9]*/' >&2)
done

PYTHONWARNINGS=ignore::SyntaxWarning uv run --script "$here/score.py" "$out" || true
