#!/bin/zsh
# Compile the telemetry probe against the same Release implementation used by the app.
set -euo pipefail
rescan_output=""
if [[ "${1:-}" == --rescan-and-reuse ]]; then
  (( $# >= 3 )) || { print -u2 'Provide the rescan JSON path and the normal capture arguments.'; exit 2; }
  rescan_output="$2"
  shift 2
fi
program=profile-settled-photo
output_index=3
if [[ "${1:-}" == --two-sources ]]; then
  program=profile-global-finite-sources
  output_index=4
  shift
  if (( $# != 4 )); then
    print -u2 'Usage: run-settled-stage-profile.sh --two-sources FIRST_RAW SECOND_RAW NATIVE_OPERATOR_REPORT NEW_OUTPUT_JSON'
    exit 2
  fi
fi
if (( $# < 4 )); then
  print -u2 'Usage: run-settled-stage-profile.sh REAL_RAW NATIVE_OPERATOR_REPORT NEW_OUTPUT_JSON CONTROL_ID ...'
  exit 2
fi
repo="${0:A:h:h:h}"
scratch="${RAWMASTER_PERF_BUILD_PATH:-$repo/.build}"
scratch="${scratch:A}"
products="$scratch/release"
module_maps="$scratch/out/Intermediates.noindex/GeneratedModuleMaps"
work="$(mktemp -d "${TMPDIR:-/tmp}/rawmaster-settled-stage.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
for bundle in RAWMaster_RAWMasterImaging RAWMaster_RAWMasterCore ImageEdit_RAWMasterImage \
              LibraryCatalog_RAWMasterLibrary PhotoExport_RAWMasterPhotoExport; do
  ln -s "$products/$bundle.bundle" "$work/$bundle.bundle"
done
map_flags=()
for module in CFlashRaw CImageEditABI CLibraryCatalogABI; do
  map_flags+=(-Xcc "-fmodule-map-file=$module_maps/$module.modulemap")
done
objects=()
for module in RAWMasterImaging RAWMasterCore RAWMasterImage RAWMasterLibrary RAWMasterPhotoExport \
              MaskAI CFlashRaw CImageEditABI CLibraryCatalogABI; do
  objects+=("$products/$module.o")
done
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$products" -I "$repo/Sources/CSQLite" -I "$repo/experiments/MaskAI/Sources/CONNXRuntime" \
  "${map_flags[@]}" "$repo/scripts/performance/$program.swift" "${objects[@]}" \
  -lsqlite3 -lz -framework AVKit -o "$work/$program"
if [[ -n "$rescan_output" ]]; then
  before_args=("$@")
  before_args[$output_index]="$rescan_output"
  RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE=1 "$work/$program" "${before_args[@]}"
  RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE=0 "$work/$program" "$@"
else
  "$work/$program" "$@"
fi
