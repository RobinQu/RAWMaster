#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
RUNTIME="$VENDOR/ONNXRuntime"
WHEEL="$VENDOR/PyPI/onnxruntime-1.27.0-cp312-cp312-macosx_14_0_arm64.whl"
mkdir -p "$VENDOR/PyPI" "$RUNTIME/lib" "$RUNTIME/include"
if [[ ! -f "$WHEEL" ]]; then
  python -m pip download --no-deps --only-binary=:all: --dest "$VENDOR/PyPI" onnxruntime==1.27.0
fi
echo "a14c2ce45312def86b77aea651f46565e45960cf5f0721bfdff449165086ab76  $WHEEL" | shasum -a 256 -c -
if [[ ! -f "$RUNTIME/lib/libonnxruntime.1.27.0.dylib" ]]; then
  unzip -p "$WHEEL" onnxruntime/capi/libonnxruntime.1.27.0.dylib > "$RUNTIME/lib/libonnxruntime.1.27.0.dylib"
fi
echo "49422a138fff12d7fcbd544373aefbffd510e473e08e18af28a8ecc3581029bf  $RUNTIME/lib/libonnxruntime.1.27.0.dylib" | shasum -a 256 -c -
ln -sf libonnxruntime.1.27.0.dylib "$RUNTIME/lib/libonnxruntime.1.dylib"
ln -sf libonnxruntime.1.27.0.dylib "$RUNTIME/lib/libonnxruntime.dylib"
if [[ ! -f "$RUNTIME/include/onnxruntime_c_api.h" ]]; then
  python "$ROOT/Scripts/extract-ort-headers.py"
fi
sed -i '' -E 's/^#define ORT_API_VERSION [0-9]+$/#define ORT_API_VERSION 27/' "$RUNTIME/include/onnxruntime_c_api.h"
python "$ROOT/Scripts/probe-ort-api.py"
