#!/bin/zsh
# Explicit release performance run. All required benchmarks must run and pass.
set -euo pipefail
cd "${0:A:h:h}"
project_root="$PWD"
source_dir=""
report_dir=""
baseline_dir=""
measure_only=0
while (( $# > 0 )); do
  case "$1" in
    --source) source_dir="$2"; shift 2 ;;
    --output) report_dir="$2"; shift 2 ;;
    --baseline-dir) baseline_dir="$2"; shift 2 ;;
    --measure-only) measure_only=1; shift ;;
    *) print -u2 'Usage: scripts/test-image-performance.sh --source RAW_DIRECTORY [--output DIRECTORY] [--baseline-dir PREVIOUS_REPORTS] [--measure-only]'; exit 2 ;;
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
ui_gate=1
phase=regression
if (( measure_only )); then ui_gate=0; phase=baseline; fi
print 'Measuring native card input in a release test window…'
RAWMASTER_UI_PERF_REPORT="$report_dir/ui.json" RAWMASTER_UI_PERF_GATE="$ui_gate" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/ui.log" -- \
  swift test --configuration release --jobs 4 --filter UIClickPerformanceTests
print 'Measuring real RAW decoding, navigation, comparison and canvas drawing…'
image_baseline=""
if [[ -n "$baseline_dir" ]]; then image_baseline="${baseline_dir:A}/image.json"; fi
RAWMASTER_RUN_IMAGE_PERF=1 RAWMASTER_IMAGE_PERF_SOURCE="${source_dir:A}" \
RAWMASTER_IMAGE_PERF_COUNT=15 RAWMASTER_IMAGE_PERF_REPORT="$report_dir/image.json" \
RAWMASTER_PERF_PHASE="$phase" RAWMASTER_IMAGE_PERF_BASELINE="$image_baseline" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/image.log" -- \
  swift test --configuration release --jobs 4 --filter ImagePerformanceTests
checker_args=("$report_dir")
if (( measure_only )); then checker_args+=(--measure-only); fi
if [[ -n "$baseline_dir" ]]; then checker_args+=(--baseline-dir "${baseline_dir:A}"); fi
python3 scripts/check-image-performance.py "${checker_args[@]}"
print "Performance reports: $report_dir"
