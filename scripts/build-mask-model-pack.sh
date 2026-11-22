#!/bin/bash
# Assemble the offline macOS arm64 pack from locally acquired, pinned artifacts.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$repo/experiments/MaskAI/Vendor"
scene=""
object=0
destination=""
usage() { echo "usage: $0 --output folder [--vendor folder] [--landscape author-export.onnx] [--object]" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) destination="$2"; shift 2;;
    --vendor) vendor="$2"; shift 2;;
    --landscape) scene="$2"; shift 2;;
    --object) object=1; shift;;
    *) usage;;
  esac
done
[[ -n "$destination" && ( -n "$scene" || "$object" -eq 1 ) ]] || usage
mkdir -p "$destination"
stage="$(mktemp -d "$destination/.pack.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
copy_verified() {
  local source="$1" relative="$2" expected="$3"
  mkdir -p "$stage/$(dirname "$relative")"
  cp -L "$source" "$stage/$relative"
  local actual
  actual="$(shasum -a 256 "$stage/$relative" | cut -d ' ' -f 1)"
  [[ "$actual" == "$expected" ]] || { echo "Unexpected SHA-256 for $relative" >&2; exit 1; }
}
runtime="ONNXRuntime/lib/libonnxruntime.1.27.0.dylib"
copy_verified "$vendor/$runtime" "$runtime" 49422a138fff12d7fcbd544373aefbffd510e473e08e18af28a8ecc3581029bf
if [[ -n "$scene" ]]; then
  copy_verified "$scene" Models/efficientvit-seg-b2-ade20k/model.onnx bdbe3961a13d75fe259f4bbc5d93dc8e4b5fe130c599acd6009ae1f382d6bc5d
fi
if [[ "$object" -eq 1 ]]; then
  encoder=Models/slimsam/vision_encoder_quantized.onnx
  decoder=Models/slimsam/prompt_encoder_mask_decoder_quantized.onnx
  copy_verified "$vendor/$encoder" "$encoder" cce23c7b2e5d4f330932738fb67ba518e04b0d99ccdd1cccd22a7da4e01f2971
  copy_verified "$vendor/$decoder" "$decoder" cb90b279f549d2cab7fd6e20c38522438c65d84bdcca3d2a764cff7d857fdce2
fi
mkdir -p "$stage/Licenses"
cp "$repo/experiments/MaskAI/Sources/CONNXRuntime/LICENSE" "$stage/Licenses/ONNXRuntime-MIT.txt"
cp "$repo/scripts/licenses/MaskAI-Apache-2.0.txt" "$stage/Licenses/Apache-2.0.txt"
cp "$repo/specs/027-mask-ai-raw-integration/model-pack.md" "$stage/Licenses/Model-sources.md"
(cd "$stage" && find . -type f -print0) | while IFS= read -r -d '' path; do
  mkdir -p "$destination/$(dirname "$path")"
  mv -f "$stage/$path" "$destination/$path"
done
echo "Verified offline mask model pack at $destination"
