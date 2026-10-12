#!/bin/bash
# Bark2 eval: FLEURS sv/en on the shipping WhisperKit config. Data and results
# live outside git in ~/Library/Application Support/Bark/eval.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
mkdir -p "$eval_dir/results"

uv run --script "$here/prep.py" "$eval_dir"

swift build -c release --package-path "$here/.." --product bark-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)/bark-eval"

# lang model: run sequentially so nothing else competes for the GPU/ANE.
for run in "sv swedish" "sv general" "en general" "en swedish"; do
  set -- $run
  echo "== $1 clips on $2 =="
  "$bin" --model "$2" --language "$1" \
    --clips "$eval_dir/fleurs/$1/clips" --out "$eval_dir/results/$1-$2.jsonl"
done

# whisper-normalizer 0.1.15 trips a harmless SyntaxWarning in a docstring.
PYTHONWARNINGS=ignore::SyntaxWarning uv run --script "$here/score.py" "$eval_dir"
