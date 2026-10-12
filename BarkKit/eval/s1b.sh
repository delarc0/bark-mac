#!/bin/bash
# Spike S1b: KB returns empty on sub-1 s Swedish. (1) suppress KB's no-speech
# token, (2) send sub-1 s audio to large-v3 with language sv. Run after run.sh.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
out="$eval_dir/s1b"
mkdir -p "$out/results"
ln -sfn "$eval_dir/sets" "$out/sets"
swift build -c release --package-path "$here/.." --product bark-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)/bark-eval"

for set in short08-sv short25-sv fleurs-sv noise; do
  "$bin" --model swedish --language sv --suppress-nospeech 1 \
    --clips "$eval_dir/sets/$set/clips" --out "$out/results/$set-kbsuppress.jsonl"
  cp "$eval_dir/results/$set-swedish.jsonl" "$out/results/$set-kb.jsonl"
done
for set in short08-sv short25-sv; do
  "$bin" --model general --language sv --clips "$eval_dir/sets/$set/clips" --out "$out/results/$set-v3sv.jsonl"
done
cp "$eval_dir/results/noise-general.jsonl" "$out/results/noise-v3.jsonl"

PYTHONWARNINGS=ignore::SyntaxWarning uv run --script "$here/score.py" "$out" --table-only
