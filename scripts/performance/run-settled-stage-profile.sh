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
products="$scratch/release"
module_map="$scratch/out/Intermediates.noindex/GeneratedModuleMaps/CFlashRaw.modulemap"
work="$(mktemp -d "${TMPDIR:-/tmp}/rawmaster-settled-stage.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
ln -s "$products/RAWMaster_RAWMasterImaging.bundle" "$work/RAWMaster_RAWMasterImaging.bundle"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$products" -I "$repo/Sources/CSQLite" -Xcc "-fmodule-map-file=$module_map" \
  "$repo/scripts/performance/$program.swift" "$products/RAWMasterImaging.o" \
  "$products/RAWMasterCore.o" "$products/CFlashRaw.o" -lsqlite3 -o "$work/$program"
if [[ -n "$rescan_output" ]]; then
  before_args=("$@")
  before_args[$output_index]="$rescan_output"
  RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE=1 "$work/$program" "${before_args[@]}"
  RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE=0 "$work/$program" "$@"
else
  "$work/$program" "$@"
fi
