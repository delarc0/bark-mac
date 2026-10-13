# /// script
# requires-python = ">=3.12"
# dependencies = ["mlx==0.32.3"]
# ///
"""8-bit copy of an mlx_whisper model folder (config.json + weights.safetensors).

usage: quantize.py <fp16 folder> <out folder> [--check <reference folder>]

Same result as mlx.nn.quantize(model, group_size=64, bits=8) on the loaded model:
every Linear and Embedding weight (the 2-D "*.weight" tensors) becomes weight,
scales and biases; conv, LayerNorm and positional embeddings stay fp16.
--check compares the output tensor by tensor with an existing 8-bit folder.
"""
import json
import sys
from pathlib import Path

import mlx.core as mx

GROUP, BITS = 64, 8

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
weights = mx.load(str(src / "weights.safetensors"))
out = {}
for key, value in weights.items():
    if key.endswith(".weight") and value.ndim == 2 and "positional" not in key:
        path = key[: -len(".weight")]
        out[key], out[f"{path}.scales"], out[f"{path}.biases"] = mx.quantize(value, group_size=GROUP, bits=BITS)
    else:
        out[key] = value
dst.mkdir(parents=True, exist_ok=True)
mx.save_safetensors(str(dst / "weights.safetensors"), out)
config = json.loads((src / "config.json").read_text())
config["quantization"] = {"group_size": GROUP, "bits": BITS}
(dst / "config.json").write_text(json.dumps(config, indent=4))
print(f"wrote {dst}: {sum(k.endswith('.scales') for k in out)} quantized tensors")

if "--check" in sys.argv:
    reference = mx.load(str(Path(sys.argv[sys.argv.index("--check") + 1]) / "weights.safetensors"))
    assert reference.keys() == out.keys(), sorted(set(reference) ^ set(out))
    diff = [k for k in out if out[k].dtype != reference[k].dtype or not mx.array_equal(out[k], reference[k]).item()]
    assert not diff, diff[:10]
    print(f"identical to the reference: {len(out)} tensors")
