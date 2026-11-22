#!/bin/zsh
# Build the independent reference with the same Release imaging and Rust/FlashRaw bridge objects.
set -euo pipefail
if [[ $# != 3 ]]; then
  print -u2 'Usage: verify-sharpen-mask-reference.sh REAL_RAW NATIVE_PHOTO_OPERATOR_JSON NEW_EVIDENCE_JSON'
  exit 2
fi
repo="${0:A:h:h:h}"
scratch="${RAWMASTER_PERF_BUILD_PATH:-$repo/.build}"
products="$scratch/release"
module_map="$scratch/out/Intermediates.noindex/GeneratedModuleMaps/CFlashRaw.modulemap"
work="$(mktemp -d "${TMPDIR:-/tmp}/rawmaster-sharpen-reference.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
ln -s "$products/RAWMaster_RAWMasterImaging.bundle" "$work/RAWMaster_RAWMasterImaging.bundle"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$products" -I "$repo/Sources/CSQLite" -Xcc "-fmodule-map-file=$module_map" \
  "$repo/scripts/performance/sharpen-mask-reference.swift" "$products/RAWMasterImaging.o" "$products/RAWMasterCore.o" \
  "$products/CFlashRaw.o" -lsqlite3 -o "$work/sharpen-mask-reference"
"$work/sharpen-mask-reference" "$1" "$2" "$3"
