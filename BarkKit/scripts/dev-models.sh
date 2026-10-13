#!/bin/bash
# Links the local eval models into the app's model layout,
# ~/Library/Application Support/Bark/Models/<id>/{config.json,weights.safetensors,tokenizer.json},
# so BarkEngine and mlx-eval run without the (not yet published) downloads.
# Makes the 8-bit large-v3 from the fp16 one first if it is missing (quantize.py).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
eval_models="$HOME/Library/Application Support/Bark/eval/models"
store="$HOME/Library/Application Support/Bark/Models"
kb_tokenizer="$(ls -d "$HOME"/.cache/huggingface/hub/models--KBLab--kb-whisper-large/snapshots/*/tokenizer.json | head -1)"
v3_tokenizer="$HOME/Documents/huggingface/models/openai/whisper-large-v3/tokenizer.json"

if [ ! -f "$eval_models/whisper-large-v3-mlx-q8/weights.safetensors" ]; then
  uv run --script "$here/quantize.py" "$eval_models/whisper-large-v3-mlx" "$eval_models/whisper-large-v3-mlx-q8"
fi

link() { # id source-folder tokenizer
  local dst="$store/$1"
  for f in "$2/config.json" "$2/weights.safetensors" "$3"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
  done
  mkdir -p "$dst"
  ln -sfn "$2/config.json" "$dst/config.json"
  ln -sfn "$2/weights.safetensors" "$dst/weights.safetensors"
  ln -sfn "$3" "$dst/tokenizer.json"
  echo "$dst"
}

link kb-whisper-large "$eval_models/kb-whisper-large-mlx" "$kb_tokenizer"
link kb-whisper-large-8bit "$eval_models/kb-whisper-large-mlx-q8" "$kb_tokenizer"
link whisper-large-v3 "$eval_models/whisper-large-v3-mlx" "$v3_tokenizer"
link whisper-large-v3-8bit "$eval_models/whisper-large-v3-mlx-q8" "$v3_tokenizer"
