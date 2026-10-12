#!/bin/bash
# Spike S1: streaming mechanisms fed in real time. Run after run.sh (sets).
# Takes about 3 hours: every mechanism except oneshot is fed at wall-clock pace.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
out="$eval_dir/s1"
mkdir -p "$out/results"
ln -sfn "$eval_dir/sets" "$out/sets"
uv run --script "$here/prep.py" "$eval_dir"
swift build -c release --package-path "$here/.." --product stream-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)/stream-eval"

# name mechanism pause prompt
mechanisms=("oneshot oneshot 0.5 1" "confirm confirm 0.5 1" "silero25 silero 0.25 1"
            "silero50 silero 0.5 1" "silero50np silero 0.5 0")
for route in "sv swedish" "en general"; do
  set -- $route
  lang=$1 model=$2
  for set in "dict-$lang" "long-$lang"; do
    for m in "${mechanisms[@]}"; do
      set -- $m
      echo "== $set $1 =="
      "$bin" --mechanism "$2" --pause "$3" --prompt "$4" --model "$model" --language "$lang" \
        --suppress-short 1 --clips "$eval_dir/sets/$set/clips" --out "$out/results/$set-$1.jsonl"
    done
  done
done

PYTHONWARNINGS=ignore::SyntaxWarning uv run --script "$here/s1_score.py" "$eval_dir"
