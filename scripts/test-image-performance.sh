#!/bin/zsh
# Explicit release performance run. All required benchmarks must run and pass.
set -euo pipefail
cd "${0:A:h:h}"
project_root="$PWD"
source_dir=""
operator_source=""
report_dir=""
baseline_dir=""
measure_only=0
background_only=0
while (( $# > 0 )); do
  case "$1" in
    --source) source_dir="$2"; shift 2 ;;
    --operator-source) operator_source="$2"; shift 2 ;;
    --output) report_dir="$2"; shift 2 ;;
    --baseline-dir) baseline_dir="$2"; shift 2 ;;
    --measure-only) measure_only=1; shift ;;
    --background) background_only=1; shift ;;
    *) print -u2 'Usage: scripts/test-image-performance.sh --source RAW_DIRECTORY [--operator-source FILE] [--output DIRECTORY] [--baseline-dir PREVIOUS_REPORTS] [--measure-only] [--background]'; exit 2 ;;
  esac
done
if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
  print -u2 'An existing RAW source directory is required; this suite cannot silently skip it.'
  exit 2
fi
mkdir -p output/performance
if [[ -z "$report_dir" ]]; then report_dir="$(mktemp -d "$PWD/output/performance/run.XXXXXX")"; fi
if [[ -d "$report_dir" ]]; then
  existing_files=("$report_dir"/*(DN))
  if (( ${#existing_files} > 0 )); then
    print -u2 'Performance output must be a new or empty directory, to prevent stale-report passes.'
    exit 2
  fi
fi
mkdir -p "$report_dir"
report_dir="${report_dir:A}"
if [[ -n "$operator_source" ]]; then
  [[ -f "$operator_source" ]] || { print -u2 "Operator RAW is missing"; exit 2; }
  raw_source="${operator_source:A}"
else
  raw_source="$(python3 -c 'import pathlib,sys; root=pathlib.Path(sys.argv[1]); extensions={".arw",".dng",".cr2",".cr3",".nef",".nraw",".orf",".raf",".rw2",".pef",".srf"}; files=sorted(p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in extensions); print(files[0] if files else "")' "$source_dir")"
fi
if [[ -z "$raw_source" ]]; then
  print -u2 'The operator regression requires at least one real RAW file in the source directory.'
  exit 2
fi
flashraw_library="${RAWMASTER_FLASHRAW_LIBRARY:-$project_root/output/tools/flashraw-target/release/libflashraw_capi.dylib}"
if [[ ! -f "$flashraw_library" && -f "$project_root/output/RAWMaster.app/Contents/Resources/FlashRaw/libflashraw_capi.dylib" ]]; then
  flashraw_library="$project_root/output/RAWMaster.app/Contents/Resources/FlashRaw/libflashraw_capi.dylib"
fi
if [[ ! -f "$flashraw_library" ]]; then
  print -u2 'FlashRaw library is required; set RAWMASTER_FLASHRAW_LIBRARY to its absolute path.'
  exit 2
fi
export RAWMASTER_FLASHRAW_LIBRARY="${flashraw_library:A}"
if [[ -z "${RAWMASTER_SCENE_DEPTH_MODEL:-}" ]]; then
  depth_root="$PWD/output/tools/monocular-depth"
  python3 scripts/build-depth-model.py --destination "$depth_root"
  export RAWMASTER_SCENE_DEPTH_MODEL="$depth_root/DepthAnythingV2SmallF16.mlmodelc"
fi
ui_gate=1
phase=regression
if (( measure_only )); then ui_gate=0; phase=baseline; fi
swift build --configuration release --build-tests -Xswiftc -enable-testing --jobs 4
failures=()
if (( ! background_only )); then
print 'Measuring native card input in a release test window…'
RAWMASTER_UI_PERF_REPORT="$report_dir/ui.json" RAWMASTER_UI_PERF_GATE="$ui_gate" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/ui.log" -- \
  swift test --configuration release -Xswiftc -enable-testing --skip-build --filter UIClickPerformanceTests || failures+=(hosted-ui)
fi
print 'Measuring real RAW decoding, navigation, comparison and canvas drawing…'
image_baseline=""
if [[ -n "$baseline_dir" ]]; then image_baseline="${baseline_dir:A}/image.json"; fi
RAWMASTER_RUN_IMAGE_PERF=1 RAWMASTER_IMAGE_PERF_SOURCE="${source_dir:A}" \
RAWMASTER_IMAGE_PERF_COUNT=15 RAWMASTER_IMAGE_PERF_REPORT="$report_dir/image.json" \
RAWMASTER_PERF_PHASE="$phase" RAWMASTER_IMAGE_PERF_BASELINE="$image_baseline" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/image.log" -- \
  swift test --configuration release -Xswiftc -enable-testing --skip-build --filter ImagePerformanceTests || failures+=(image-pipeline)
print 'Measuring the complete FlashRaw interactive operator sequence…'
RAWMASTER_FLASHRAW_LIBRARY="${flashraw_library:A}" RAWMASTER_REQUIRE_FLASHRAW=1 \
RAWMASTER_CANONICAL_FLASHRAW=0 RAWMASTER_INTERACTIVE_PERF=1 RAWMASTER_INTERACTIVE_PERF_ONLY='' \
RAWMASTER_INTERACTIVE_PREWARM=1 RAWMASTER_INTERACTIVE_RAW_BASE_CACHE=1 \
RAWMASTER_INTERACTIVE_PERF_SOURCE="$raw_source" RAWMASTER_INTERACTIVE_PERF_OUTPUT="$report_dir/interactive" \
  python3 scripts/run-performance-command.py --timeout 300 --log "$report_dir/interactive.log" -- \
  swift test --configuration release -Xswiftc -enable-testing --skip-build --filter EditingInteractivePerformanceTests || failures+=(interactive-sequence)
interactive_checker_args=("$report_dir/interactive/interactive-performance.json" --output "$report_dir/interactive-comparison.json")
if (( measure_only )); then interactive_checker_args+=(--measure-only); fi
if [[ -n "$baseline_dir" ]]; then interactive_checker_args+=(--baseline "${baseline_dir:A}/interactive/interactive-performance.json"); fi
python3 scripts/check-interactive-performance.py "${interactive_checker_args[@]}" || failures+=(interactive-comparison)
print 'Measuring individual parameter changes and verifying the rendered pixels…'
RAWMASTER_FLASHRAW_LIBRARY="${flashraw_library:A}" RAWMASTER_CONTROL_RAW="$raw_source" \
RAWMASTER_CONTROL_REPORT="$report_dir/controls.json" RAWMASTER_CONTROL_SAMPLES=20 RAWMASTER_CONTROL_ONLY='' \
  python3 scripts/run-performance-command.py --timeout 600 --log "$report_dir/controls.log" -- \
  swift test --configuration release -Xswiftc -enable-testing --skip-build --filter IndividualControlPerformanceTests || failures+=(control-sequence)
control_args=("$report_dir/controls.json" --output "$report_dir/control-comparison.json")
if (( measure_only )); then
  control_args+=(--measure-only)
else
  if [[ -n "$baseline_dir" ]]; then
    control_args+=(--baseline "${baseline_dir:A}/controls.json")
  else
    control_args+=(--verify-pixels)
  fi
fi
python3 scripts/check-control-performance.py "${control_args[@]}" || failures+=(control-comparison)
print 'Measuring source-bound analysis, sampling and the offscreen scopes…'
RAWMASTER_INSPECTION_RAW="$raw_source" RAWMASTER_INSPECTION_REPORT="$report_dir/inspection.json" \
RAWMASTER_INSPECTION_ONLY='' RAWMASTER_INSPECTION_SAMPLES=10 \
  python3 scripts/run-performance-command.py --timeout 300 --log "$report_dir/inspection.log" -- \
  swift test --configuration release -Xswiftc -enable-testing --skip-build --filter PhotoInspectionPerformanceTests/testRealRAWAnalysisAndInspection || failures+=(inspection)
inspection_args=("$report_dir/inspection.json" --output "$report_dir/inspection-comparison.json")
if [[ -n "$baseline_dir" && -f "${baseline_dir:A}/inspection.json" ]]; then
  inspection_args+=(--baseline "${baseline_dir:A}/inspection.json")
fi
python3 scripts/check-inspection-performance.py "${inspection_args[@]}" || failures+=(inspection-comparison)
if (( background_only )); then
  print 'Completed background image and operator measurements. The hosted UI release gate requires the dedicated desktop session.'
  if (( ${#failures} )); then print -u2 "Failed checks: ${failures[*]}"; exit 1; fi
  exit 0
fi
checker_args=("$report_dir")
if (( measure_only )); then checker_args+=(--measure-only); fi
if [[ -n "$baseline_dir" ]]; then checker_args+=(--baseline-dir "${baseline_dir:A}"); fi
python3 scripts/check-image-performance.py "${checker_args[@]}" || failures+=(image-comparison)
if (( ${#failures} )); then print -u2 "Failed checks: ${failures[*]}"; exit 1; fi
print "Performance reports: $report_dir"
