#!/bin/bash
# P1a gate: S0's matrix plus dict/long and --language auto, every clip fed through
# DictationSession (mlx-eval --pipeline), per variant (fp16, q8 = 8-bit), scored against
# baseline-mlx.json; then dict-sv/dict-en fed at real-time pace for release-to-final.
# Results: <eval dir>/p1a/<variant>[-rt]/results, named by route so variants share baseline keys.
# usage: p1a.sh [fp16] [q8]   (default: both)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
"$here/../scripts/dev-models.sh" > /dev/null
uv run --script "$here/prep.py" "$eval_dir"
swift build -c release --package-path "$here/.." --product mlx-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)/mlx-eval"
score() { PYTHONWARNINGS=ignore::SyntaxWarning uv run --script "$here/score.py" "$@"; }

runs=("fleurs-sv swedish sv" "fleurs-sv general sv"
  "fleurs-en general en" "fleurs-en swedish en"
  "short08-sv swedish sv" "short25-sv swedish sv"
  "short08-en general en" "short25-en general en"
  "noise swedish sv" "noise general en"
  "dict-sv swedish sv" "dict-en general en"
  "long-sv swedish sv" "long-en general en"
  "fleurs-sv auto auto" "fleurs-en auto auto")

variants=("$@")
[ $# -eq 0 ] && variants=(fp16 q8)
for variant in "${variants[@]}"; do
  bits=""; [ "$variant" = q8 ] && bits=8
  out="$eval_dir/p1a/$variant"
  mkdir -p "$out/results" "$out-rt/results"
  ln -sfn "$eval_dir/sets" "$out/sets"
  ln -sfn "$eval_dir/sets" "$out-rt/sets"
  for run in "${runs[@]}"; do
    set -- $run
    echo "== $variant: $1 on $2 ($3) =="
    "$bin" --pipeline --model "$2$bits" --language "$3" \
      --clips "$eval_dir/sets/$1/clips" --out "$out/results/$1-$2.jsonl" 2> >(grep -v '^\[mlx-eval\] [0-9]*/' >&2)
  done
  for run in "dict-sv swedish sv" "dict-en general en"; do
    set -- $run
    echo "== $variant: $1 on $2 ($3), real time =="
    "$bin" --pipeline --realtime 1 --model "$2$bits" --language "$3" \
      --clips "$eval_dir/sets/$1/clips" --out "$out-rt/results/$1-$2.jsonl" 2> >(grep -v '^\[mlx-eval\] [0-9]*/' >&2)
  done
  echo "== $variant =="
  score "$out" --baseline "$here/baseline-mlx.json" || true
  score "$out-rt" --table-only
done
