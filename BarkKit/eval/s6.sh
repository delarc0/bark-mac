#!/bin/bash
# Spike S6: vocabulary prompting. Engine-only mlx-eval runs of the prompt conditions into
# ~/Library/Application Support/Bark/eval/s6/results, scored by eval/s6_score.py.
# Waits for any other MLX process and requires AC power (timings only count on a charger).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_dir="$HOME/Library/Application Support/Bark/eval"
out="$eval_dir/s6"
mkdir -p "$out/results" "$out/sets"

while pgrep -f mlx-eval > /dev/null || pgrep -f mlx_whisper > /dev/null; do
  echo "another MLX process is running; waiting"
  sleep 10
done
if ! pmset -g batt | grep -q "AC Power"; then
  echo "not on AC power" >&2
  exit 1
fi

python3 "$here/s6_prompts.py" --sets "$eval_dir/sets" --out "$out/prompts"
swift build -c release --package-path "$here/.." --product mlx-eval
bin="$(swift build -c release --package-path "$here/.." --show-bin-path)/mlx-eval"

# Same shortcut as mlx.sh: one 30 s window, so clips over 30 s are skipped through filtered copies.
for set in fleurs-sv fleurs-en dict-sv dict-en short08-sv short08-en noise; do
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

run() { # set model language condition prompts-file
  echo "== $1 / $4 / $2 =="
  local extra=()
  [ -n "$5" ] && extra=(--prompts "$out/prompts/$5")
  "$bin" --model "$2" --language "$3" ${extra[@]+"${extra[@]}"} \
    --clips "$out/sets/$1/clips" --out "$out/results/$1-$4-$2.jsonl" 2> >(grep -v '^\[mlx-eval\] [0-9]*/' >&2)
}

run fleurs-sv swedish8 sv none ""
run fleurs-sv swedish8 sv own+40 fleurs-sv-own+40.json
run fleurs-sv swedish8 sv 40 fleurs-sv-40.json
run fleurs-sv swedish8 sv own+40-glossary fleurs-sv-own+40-glossary.json
run fleurs-sv swedish8 sv own+150 fleurs-sv-own+150.json
run fleurs-sv swedish8 sv none-last ""
run dict-sv swedish8 sv none ""
run dict-sv swedish8 sv own+40 dict-sv-own+40.json
run dict-sv swedish8 sv 40 dict-sv-40.json
run fleurs-en general8 en none ""
run fleurs-en general8 en own+40 fleurs-en-own+40.json
run fleurs-en general8 en 40 fleurs-en-40.json
run fleurs-en general8 en own+40-glossary fleurs-en-own+40-glossary.json
run dict-en general8 en none ""
run dict-en general8 en own+40 dict-en-own+40.json
run dict-en general8 en 40 dict-en-40.json
run noise swedish8 sv 40 noise-40-fleurs-sv.json
run noise general8 en 40 noise-40-fleurs-en.json
run short08-sv swedish8 sv 40 short08-sv-40-fleurs-sv.json
run short08-en general8 en 40 short08-en-40-fleurs-en.json

PYTHONWARNINGS=ignore::SyntaxWarning VIRTUAL_ENV= uv run --script "$here/s6_score.py" "$eval_dir" | tee "$out/report.txt"
