#!/bin/bash
# Publishes the two default Bark2 models (8-bit MLX conversions) to Hugging Face.
#   --stage (default): assemble ~/Library/Application Support/Bark/publish/<repo>/ from the local
#       models (hard links), plus a README model card, LICENSE (and NOTICE for KB), and manifest.json.
#   --upload: refuses unless BARK_PUBLISH_GO=1 and `hf auth whoami` succeeds; creates the public
#       repos and uploads the staged folders. Erik runs this, once, when he says go.
#   --apply-urls [--target f] [--manifest f]: point the two 8-bit manifests in ModelStore.swift at
#       the published Hugging Face URLs, checking size and sha256 against the staged manifest.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
store="$HOME/Library/Application Support/Bark/Models"
publish="$HOME/Library/Application Support/Bark/publish"
manifest_json="$publish/manifest.json"

model_ids=(kb-whisper-large-8bit whisper-large-v3-8bit)

repo_of() { case "$1" in
  kb-whisper-large-8bit) echo "lab37/kb-whisper-large-mlx-8bit" ;;
  whisper-large-v3-8bit) echo "lab37/whisper-large-v3-mlx-8bit" ;;
  *) echo "unknown model $1" >&2; exit 1 ;; esac; }

license_of() { case "$1" in
  kb-whisper-large-8bit) echo "apache" ;;
  whisper-large-v3-8bit) echo "mit" ;;
  *) echo "unknown model $1" >&2; exit 1 ;; esac; }

usage() {
  cat >&2 <<'EOF'
usage: publish-models.sh [--stage] | --upload | --apply-urls [--target <ModelStore.swift>] [--manifest <manifest.json>]
EOF
}

mode="stage"
target="$repo_root/BarkKit/Sources/BarkEngine/ModelStore.swift"
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) mode="stage" ;;
    --upload) mode="upload" ;;
    --apply-urls) mode="apply" ;;
    --target) target="$2"; shift ;;
    --manifest) manifest_json="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
size_of() { stat -f %z "$1"; }

# Hard link so staging costs no disk; cp fallback for cross-volume setups.
link_file() {
  local src dst
  src="$(realpath "$1")"
  dst="$2"
  ln -f "$src" "$dst" 2>/dev/null || cp -p "$src" "$dst"
}

apache_license() {
  cat <<'EOF'

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
EOF
}

mit_license() {
  cat <<'EOF'
MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
}

kb_notice() {
  cat <<'EOF'
This repository contains an MLX conversion of kb-whisper-large, developed by
KBLab at the National Library of Sweden
(https://huggingface.co/KBLab/kb-whisper-large) and licensed under the Apache
License, Version 2.0. The conversion is published by LAB37 for the Bark app.
EOF
}

# Card for the KB repo. Uses globals set by stage_model.
write_card_kb() {
  cat > "$STAGE/README.md" <<EOF
---
license: apache-2.0
tags:
  - whisper
  - mlx
  - speech-recognition
  - swedish
---

# kb-whisper-large-mlx-8bit

MLX conversion of [KBLab/kb-whisper-large](https://huggingface.co/KBLab/kb-whisper-large),
quantized to 8-bit (group 64). This is the Swedish model of
[Bark](https://github.com/delarc0/bark-mac): on-device push-to-talk dictation and meeting notes
on Apple Silicon, decoded by Bark's own Whisper engine on mlx-swift.

## Files

| file | bytes | sha256 |
| --- | ---: | --- |
| config.json | $SIZE_CONFIG | $SHA_CONFIG |
| weights.safetensors | $SIZE_WEIGHTS | $SHA_WEIGHTS |
| tokenizer.json | $SIZE_TOKENIZER | $SHA_TOKENIZER |

## How it was made

1. Converted with \`convert.py\` from Apple's
   [mlx-examples](https://github.com/ml-explore/mlx-examples) whisper example (git main,
   October 2026):
   \`python convert.py --torch-name-or-path KBLab/kb-whisper-large --mlx-path <out> --dtype float16\`,
   then \`model.safetensors\` renamed to \`weights.safetensors\` (the name mlx-whisper loads).
2. \`tokenizer.json\` copied verbatim from KBLab/kb-whisper-large, revision
   [\`d5d5984\`](https://huggingface.co/KBLab/kb-whisper-large/tree/d5d5984b4d8f7c4847a8ea203f1976285fb28300).
3. Quantized with BarkKit's \`scripts/quantize.py\` (mlx 0.32.3): affine 8-bit, group size 64,
   on every Linear and Embedding weight; conv, LayerNorm and the positional embedding stay fp16.
   \`config.json\` gains \`"quantization": {"group_size": 64, "bits": 8}\`.

On Bark's FLEURS Swedish eval this 8-bit build returns transcripts identical to the fp16
conversion (59 of 59 clips, WER 5.80%), decodes about 18% faster and halves memory
(measurements: tasks/bark2.md, sections S8 and P1a).

## Licence

[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0), the licence of the source model;
see LICENSE. KBLab is credited in NOTICE.
EOF
}

# Card for the large-v3 repo. Uses globals set by stage_model.
write_card_v3() {
  cat > "$STAGE/README.md" <<EOF
---
license: mit
tags:
  - whisper
  - mlx
  - speech-recognition
---

# whisper-large-v3-mlx-8bit

MLX conversion of [openai/whisper-large-v3](https://huggingface.co/openai/whisper-large-v3),
quantized to 8-bit (group 64). This is the general (non-Swedish) model of
[Bark](https://github.com/delarc0/bark-mac): on-device push-to-talk dictation and meeting notes
on Apple Silicon, decoded by Bark's own Whisper engine on mlx-swift.

## Files

| file | bytes | sha256 |
| --- | ---: | --- |
| config.json | $SIZE_CONFIG | $SHA_CONFIG |
| weights.safetensors | $SIZE_WEIGHTS | $SHA_WEIGHTS |
| tokenizer.json | $SIZE_TOKENIZER | $SHA_TOKENIZER |

## How it was made

1. Converted with \`convert.py\` from Apple's
   [mlx-examples](https://github.com/ml-explore/mlx-examples) whisper example (git main,
   October 2026):
   \`python convert.py --torch-name-or-path openai/whisper-large-v3 --mlx-path <out> --dtype float16\`,
   then \`model.safetensors\` renamed to \`weights.safetensors\` (the name mlx-whisper loads).
2. \`tokenizer.json\` copied verbatim from openai/whisper-large-v3.
3. Quantized with BarkKit's \`scripts/quantize.py\` (mlx 0.32.3): affine 8-bit, group size 64,
   on every Linear and Embedding weight; conv, LayerNorm and the positional embedding stay fp16.
   \`config.json\` gains \`"quantization": {"group_size": 64, "bits": 8}\`.

On Bark's eval (FLEURS English and Swedish, dictation, long-form and noise sets) this 8-bit
build measures the same WER as the fp16 conversion on every set
(measurements: tasks/bark2.md, section P1a).

## Licence

[MIT](https://opensource.org/licenses/MIT), the licence of the source model; see LICENSE.
EOF
}

stage_model() {
  local id="$1"
  local repo srcdir
  repo="$(repo_of "$id")"
  srcdir="$store/$id"
  STAGE="$publish/${repo#*/}"

  for f in config.json weights.safetensors tokenizer.json; do
    [ -f "$srcdir/$f" ] || { echo "missing $srcdir/$f" >&2; exit 1; }
  done

  case "$STAGE" in
    "$publish"/*) rm -rf "$STAGE" ;;
    *) echo "refusing to clear unexpected path: $STAGE" >&2; exit 1 ;;
  esac
  mkdir -p "$STAGE"

  for f in config.json weights.safetensors tokenizer.json; do
    link_file "$srcdir/$f" "$STAGE/$f"
  done

  SIZE_CONFIG="$(size_of "$STAGE/config.json")"; SHA_CONFIG="$(sha_of "$STAGE/config.json")"
  SIZE_WEIGHTS="$(size_of "$STAGE/weights.safetensors")"; SHA_WEIGHTS="$(sha_of "$STAGE/weights.safetensors")"
  SIZE_TOKENIZER="$(size_of "$STAGE/tokenizer.json")"; SHA_TOKENIZER="$(sha_of "$STAGE/tokenizer.json")"

  case "$(license_of "$id")" in
    apache) apache_license > "$STAGE/LICENSE"; kb_notice > "$STAGE/NOTICE"; write_card_kb ;;
    mit) mit_license > "$STAGE/LICENSE"; write_card_v3 ;;
  esac

  local url="https://huggingface.co/$repo/resolve/main"
  FILES_JSON="$(cat <<EOF
        { "name": "config.json", "size": $SIZE_CONFIG, "sha256": "$SHA_CONFIG", "url": "$url/config.json" },
        { "name": "weights.safetensors", "size": $SIZE_WEIGHTS, "sha256": "$SHA_WEIGHTS", "url": "$url/weights.safetensors" },
        { "name": "tokenizer.json", "size": $SIZE_TOKENIZER, "sha256": "$SHA_TOKENIZER", "url": "$url/tokenizer.json" }
EOF
)"
  MODEL_JSON="$(cat <<EOF
    {
      "id": "$id",
      "repo": "$repo",
      "license": "$(license_of "$id")",
      "files": [
$FILES_JSON
      ]
    }
EOF
)"

  echo "staged $repo at $STAGE"
  for f in config.json weights.safetensors tokenizer.json README.md LICENSE; do
    printf '  %-20s %12s bytes\n' "$f" "$(size_of "$STAGE/$f")"
  done
  if [ -f "$STAGE/NOTICE" ]; then
    printf '  %-20s %12s bytes\n' "NOTICE" "$(size_of "$STAGE/NOTICE")"
  fi
}

do_stage() {
  mkdir -p "$publish"
  local models=()
  for id in "${model_ids[@]}"; do
    stage_model "$id"
    models+=("$MODEL_JSON")
  done

  {
    printf '{\n'
    printf '  "tool": "BarkKit/scripts/publish-models.sh --stage",\n'
    printf '  "models": [\n'
    local i
    for i in "${!models[@]}"; do
      if [ "$i" -gt 0 ]; then
        printf ',\n'
      fi
      printf '%s' "${models[$i]}"
    done
    printf '\n  ]\n}\n'
  } > "$manifest_json"
  echo "wrote $manifest_json"

  cat <<EOF

--upload would, with BARK_PUBLISH_GO=1 and a valid hf login:
EOF
  for id in "${model_ids[@]}"; do
    local repo
    repo="$(repo_of "$id")"
    cat <<EOF
  hf repos create $repo --public
  hf upload $repo "$publish/${repo#*/}" .
EOF
  done
  cat <<EOF
then rewrite the app's download URLs:
  BarkKit/scripts/publish-models.sh --apply-urls
EOF
}

do_upload() {
  if [ "${BARK_PUBLISH_GO:-}" != "1" ]; then
    echo "refusing: publishing needs BARK_PUBLISH_GO=1 (Erik's go)" >&2
    exit 1
  fi
  local cli_auth=() cli_create=() cli_upload=()
  if command -v hf >/dev/null 2>&1; then
    cli_auth=(hf auth whoami)
    cli_create=(hf repos create --public)
    cli_upload=(hf upload)
  elif command -v huggingface-cli >/dev/null 2>&1; then
    cli_auth=(huggingface-cli whoami)
    cli_create=(huggingface-cli repo create)
    cli_upload=(huggingface-cli upload)
  else
    echo "refusing: no hf CLI found (pip install huggingface_hub, then hf auth login)" >&2
    exit 1
  fi

  local who
  if ! who="$("${cli_auth[@]}" 2>&1)"; then
    echo "refusing: '${cli_auth[*]}' failed; log in first (hf auth login):" >&2
    echo "$who" >&2
    exit 1
  fi
  echo "authenticated: $who"

  [ -f "$manifest_json" ] || { echo "no staged manifest at $manifest_json; run --stage first" >&2; exit 1; }

  local id repo stage f
  for id in "${model_ids[@]}"; do
    repo="$(repo_of "$id")"
    stage="$publish/${repo#*/}"
    for f in config.json weights.safetensors tokenizer.json README.md LICENSE; do
      [ -f "$stage/$f" ] || { echo "incomplete staging: missing $stage/$f; rerun --stage" >&2; exit 1; }
    done
    if [ "$(license_of "$id")" = "apache" ]; then
      [ -f "$stage/NOTICE" ] || { echo "incomplete staging: missing $stage/NOTICE; rerun --stage" >&2; exit 1; }
    fi
    echo "creating public repo $repo"
    "${cli_create[@]}" "$repo" || echo "repo create failed (it may already exist); upload will verify access"
    echo "uploading $stage -> $repo"
    "${cli_upload[@]}" "$repo" "$stage" .
  done

  cat <<EOF

published. next steps:
  BarkKit/scripts/publish-models.sh --apply-urls
  cd BarkKit && swift build && swift test
EOF
}

do_apply() {
  [ -f "$manifest_json" ] || { echo "no staged manifest at $manifest_json; run --stage first" >&2; exit 1; }
  [ -f "$target" ] || { echo "no such target: $target" >&2; exit 1; }
  python3 - "$target" "$manifest_json" <<'PY'
import json
import re
import sys

target, manifest_path = sys.argv[1], sys.argv[2]
by_id = {m["id"]: m for m in json.load(open(manifest_path))["models"]}
enum_of = {"kb-whisper-large-8bit": "swedish8", "whisper-large-v3-8bit": "general8"}

src = open(target).read()
out = src

old_comment = """    // shortcut: no published model repo yet, fill in when Erik publishes. Every manifest URL is
    // built on this placeholder, so a download fails until it is replaced."""
new_comment = """    // The fp16 pair has no published repo, so its URLs stay on this placeholder and an fp16
    // download fails until it is replaced. The 8-bit defaults pass their Hugging Face repo."""
if out.count(old_comment) != 1:
    sys.exit("anchor not found: unpublishedBaseURL comment")
out = out.replace(old_comment, new_comment)

old_helper = r"""    static func manifest(_ id: String, _ files: [(name: String, size: Int64, sha256: String)]) -> ModelManifest {
        ModelManifest(id: id, files: files.map {
            File(name: $0.name, url: unpublishedBaseURL.appending(path: "\(id)/\($0.name)"), sha256: $0.sha256, size: $0.size)
        })
    }"""
new_helper = r"""    static func manifest(_ id: String, repo: String? = nil, _ files: [(name: String, size: Int64, sha256: String)]) -> ModelManifest {
        ModelManifest(id: id, files: files.map { file in
            let url = repo.map { URL(string: "https://huggingface.co/\($0)/resolve/main/\(file.name)")! }
                ?? unpublishedBaseURL.appending(path: "\(id)/\(file.name)")
            return File(name: file.name, url: url, sha256: file.sha256, size: file.size)
        })
    }"""
if out.count(old_helper) != 1:
    sys.exit("anchor not found: manifest helper")
out = out.replace(old_helper, new_helper)

def swift_int(n):
    s = str(n)
    parts = []
    while s:
        parts.append(s[-3:])
        s = s[:-3]
    return "_".join(reversed(parts))

for model_id, enum_name in enum_of.items():
    m = by_id.get(model_id)
    if m is None:
        sys.exit(f"no {model_id} in {manifest_path}")
    old_open = f"manifest(ModelID.{enum_name}, ["
    new_open = f'manifest(ModelID.{enum_name}, repo: "{m["repo"]}", ['
    if out.count(old_open) != 1:
        sys.exit(f"anchor not found: {old_open}")
    out = out.replace(old_open, new_open)
    start = out.index(new_open) + len(new_open)
    end = out.index("]),", start)
    block = out[start:end]
    files = {f["name"]: f for f in m["files"]}

    def rewrite(match):
        name, size, sha = match.group(1), int(match.group(2).replace("_", "")), match.group(3)
        f = files.get(name)
        if f is None:
            sys.exit(f"{model_id}: {name} not in the staged manifest")
        if f["size"] != size or f["sha256"] != sha:
            sys.exit(f"{model_id}/{name}: ModelStore.swift has size {size}, sha256 {sha}; "
                     f"the staged manifest has {f['size']}, {f['sha256']}. Restage and reconcile first.")
        return f'("{name}", {swift_int(f["size"])}, "{f["sha256"]}")'

    block, n = re.subn(r'\("([^"]+)", ([\d_]+), "([0-9a-f]{64})"\)', rewrite, block)
    if n != 3:
        sys.exit(f"{model_id}: expected 3 file tuples, found {n}")
    out = out[:start] + block + out[end:]

open(target, "w").write(out)
for model_id in enum_of:
    m = by_id[model_id]
    print(f"{model_id}: urls -> https://huggingface.co/{m['repo']}/resolve/main, sizes and sha256 verified against the manifest")
print(f"rewrote {target}")
PY
}

case "$mode" in
  stage) do_stage ;;
  upload) do_upload ;;
  apply) do_apply ;;
esac
