#!/bin/bash
# Spike S3: Bark's energy gate vs Silero VAD (FluidAudio) in front of the
# shipping decoder. Run after run.sh (it reuses the sets and the binaries).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
s3="$eval_dir/s3"
swift build -c release --package-path "$here/.." --product bark-eval
swift build -c release --package-path "$here/.." --product fluid-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)"

decode() {  # clips-dir out.jsonl model lang
  if compgen -G "$1/*.wav" >/dev/null; then
    "$bin/bark-eval" --model "$3" --language "$4" --clips "$1" --out "$2"
  else
    : > "$2"
  fi
}

mkdir -p "$s3/results"
for route in "sv swedish" "en general"; do
  set -- $route
  lang=$1 model=$2
  for set in "level0-$lang" "level20-$lang" "level30-$lang" noise; do
    for gate in none energy silero85 silero50; do
      name="$set@$gate-$model"
      echo "== $name =="
      if [ "$gate" = none ]; then
        decode "$eval_dir/sets/$set/clips" "$s3/results/$name.jsonl" "$model" "$lang"
        continue
      fi
      gated="$s3/gated/$set@$gate"
      rm -rf "$gated"
      case $gate in
        energy) "$bin/fluid-eval" gate --kind energy --clips "$eval_dir/sets/$set/clips" --out "$gated" ;;
        silero85) "$bin/fluid-eval" gate --kind silero --threshold 0.85 --clips "$eval_dir/sets/$set/clips" --out "$gated" ;;
        silero50) "$bin/fluid-eval" gate --kind silero --threshold 0.5 --clips "$eval_dir/sets/$set/clips" --out "$gated" ;;
      esac
      decode "$gated" "$s3/results/$name.jsonl" "$model" "$lang"
    done
  done
done

PYTHONWARNINGS=ignore::SyntaxWarning uv run --script "$here/s3_score.py" "$eval_dir"
