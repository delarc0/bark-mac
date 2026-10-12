#!/bin/bash
# Bark2 eval gate, engine-only: every set on the shipping WhisperKit config.
# Data and results live outside git in ~/Library/Application Support/Bark/eval.
# usage: run.sh [--write-baseline]
set -euo pipefail
score_args=("$@")

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
mkdir -p "$eval_dir/results"

uv run --script "$here/prep.py" "$eval_dir"

swift build -c release --package-path "$here/.." --product bark-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)/bark-eval"

# set model language: sequential, so nothing else competes for the GPU/ANE.
# KB on English is not a shipping route; it stays as the translation canary.
for run in \
  "fleurs-sv swedish sv" "fleurs-sv general sv" \
  "fleurs-en general en" "fleurs-en swedish en" \
  "short08-sv swedish sv" "short25-sv swedish sv" \
  "short08-en general en" "short25-en general en" \
  "noise swedish sv" "noise general en"; do
  set -- $run
  echo "== $1 on $2 ($3) =="
  "$bin" --model "$2" --language "$3" \
    --clips "$eval_dir/sets/$1/clips" --out "$eval_dir/results/$1-$2.jsonl"
done

# whisper-normalizer 0.1.15 trips a harmless SyntaxWarning in a docstring.
PYTHONWARNINGS=ignore::SyntaxWarning uv run --script "$here/score.py" "$eval_dir" ${score_args[@]+"${score_args[@]}"}
