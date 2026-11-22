#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/Vendor/ONNXRuntime"
MODELS="$ROOT/Vendor/Models"
mkdir -p "$ROOT/Vendor" "$MODELS"

fetch() {
  local url="$1" destination="$2" expected="$3"
  if [[ -f "$destination" ]]; then
    local actual
    actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      echo "cached $(basename "$destination")"
      return
    fi
    rm -f "$destination"
  fi
  mkdir -p "$(dirname "$destination")"
  echo "download $(basename "$destination")"
  curl --fail --location --continue-at - --retry 5 --retry-all-errors --retry-delay 2 --output "$destination.tmp" "$url"
  local actual
  actual="$(shasum -a 256 "$destination.tmp" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA-256 mismatch for $destination: $actual != $expected" >&2
    rm -f "$destination.tmp"
    exit 1
  fi
  mv "$destination.tmp" "$destination"
}

if [[ ! -f "$RUNTIME/lib/libonnxruntime.dylib" ]]; then
  "$ROOT/Scripts/install-runtime.sh"
fi

fetch_model() {
  local path="$1" expected="$2"
  fetch "https://lightflow.dev/models/$path" "$MODELS/$path" "$expected"
}

fetch "https://huggingface.co/Ko033/isnet-general-use-onnx/resolve/5349b617911fd60c619b52f32e2b593517b78df3/onnx/model_fp16.onnx" "$MODELS/isnet-general/model_fp16.onnx" "0857167263ad816d67c26852b99c2861e46a86c9a889527061a5eb2a6f90d32c"
fetch_model "efficientvit-seg-b2-ade20k/model.onnx" "e6df30d2fa120b86364e0b5158a278f4550fd9f1ebeda3ec342683da55872f7d"
fetch "https://huggingface.co/Xenova/slimsam-77-uniform/resolve/5850ab45f587c112167512ffef949107115e26a0/onnx/vision_encoder_quantized.onnx" "$MODELS/slimsam/vision_encoder_quantized.onnx" "cce23c7b2e5d4f330932738fb67ba518e04b0d99ccdd1cccd22a7da4e01f2971"
fetch "https://huggingface.co/Xenova/slimsam-77-uniform/resolve/5850ab45f587c112167512ffef949107115e26a0/onnx/prompt_encoder_mask_decoder_quantized.onnx" "$MODELS/slimsam/prompt_encoder_mask_decoder_quantized.onnx" "cb90b279f549d2cab7fd6e20c38522438c65d84bdcca3d2a764cff7d857fdce2"
fetch "https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/a3cf03147a9b86c78475139115c8ac142577352d/onnx/model_quantized.onnx" "$MODELS/dfine-s-coco/model_quantized.onnx" "1929a508f43c2d60f62f32308506cec21b31c7e4518c5e0458ca75688d6faa8f"
fetch "https://huggingface.co/senty-au/selfie_multiclass_256x256-ONNX/resolve/6db8421a7150ac20558f2c24675078eb3a1a04d0/onnx/model.onnx" "$MODELS/selfie-multiclass/model.onnx" "35ec1ecd9ee7f85073c99c00020b7f6751b69506eeacf683bc8665f6117f85b0"
fetch "https://huggingface.co/opencv/face_detection_yunet/resolve/3cc26e7f1014a5ee5d74a42acee58bafc9d0a310/face_detection_yunet_2023mar.onnx" "$MODELS/yunet/face_detection_yunet_2023mar.onnx" "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
fetch "https://huggingface.co/senty-au/face_landmarks_detector-ONNX/resolve/337d58218b5b1cc597ca3c67360880b920f6ce7b/onnx/model.onnx" "$MODELS/face-landmarks/model.onnx" "7d6e82dee82a1dca5fbddb282b3cc74571833a530de317fc22ae325c3358beeb"

echo "MaskAI native dependencies are ready."
