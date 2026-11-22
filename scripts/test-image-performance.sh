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
perf_build_path="${RAWMASTER_PERF_BUILD_PATH:-$project_root/.build}"
swift build --scratch-path "$perf_build_path" --configuration release --build-tests -Xswiftc -enable-testing --jobs 4
# Freeze the executable and its bundled models once. Every stage in this report
# uses those same bytes even when another development build finishes meanwhile.
xctest_executable="$(xcrun --find xctest)"
test_products="$report_dir/test-products"
mkdir "$test_products"
for test_module in RAWMasterImagingTests RAWMasterUITests; do
  ditto "$perf_build_path/release/$test_module.xctest" "$test_products/$test_module.xctest"
done
python3 - "$test_products" "$report_dir/test-build.json" "$RAWMASTER_FLASHRAW_LIBRARY" <<'PYINFO'
import hashlib,json,platform,sys
from pathlib import Path
products, report, flashraw = map(Path,sys.argv[1:])
def digest_file(path):
    with path.open("rb") as source:
        digest = hashlib.sha256()
        for block in iter(lambda:source.read(1<<20),b""): digest.update(block)
        return digest.hexdigest()
digests = {}
for p in sorted(products.glob("*.xctest")):
    digests[p.stem] = digest_file(p/"Contents"/"MacOS"/p.stem)
report.write_text(json.dumps({"build":"Release","system":platform.platform(),"testBinariesSHA256":digests,
    "flashRawLibrarySHA256":digest_file(flashraw)},indent=2)+"\n")
PYINFO
failures=()
if (( ! background_only )); then
print 'Measuring native card input in a release test window…'
RAWMASTER_UI_PERF_REPORT="$report_dir/ui.json" RAWMASTER_UI_PERF_GATE="$ui_gate" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/ui.log" -- \
  "$xctest_executable" -XCTest "RAWMasterUITests.UIClickPerformanceTests" "$test_products/RAWMasterUITests.xctest" || failures+=(hosted-ui)
fi
print 'Measuring real RAW decoding, navigation, comparison and canvas drawing…'
image_baseline=""
if [[ -n "$baseline_dir" ]]; then image_baseline="${baseline_dir:A}/image.json"; fi
RAWMASTER_RUN_IMAGE_PERF=1 RAWMASTER_IMAGE_PERF_SOURCE="${source_dir:A}" \
RAWMASTER_IMAGE_PERF_COUNT=15 RAWMASTER_IMAGE_PERF_REPORT="$report_dir/image.json" \
RAWMASTER_PERF_PHASE="$phase" RAWMASTER_IMAGE_PERF_BASELINE="$image_baseline" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/image.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.ImagePerformanceTests" "$test_products/RAWMasterImagingTests.xctest" || failures+=(image-pipeline)
print 'Measuring the complete FlashRaw interactive operator sequence…'
RAWMASTER_FLASHRAW_LIBRARY="${flashraw_library:A}" RAWMASTER_REQUIRE_FLASHRAW=1 \
RAWMASTER_CANONICAL_FLASHRAW=0 RAWMASTER_INTERACTIVE_PERF=1 RAWMASTER_INTERACTIVE_PERF_ONLY='' \
RAWMASTER_INTERACTIVE_PREWARM=1 RAWMASTER_INTERACTIVE_RAW_BASE_CACHE=1 \
RAWMASTER_INTERACTIVE_PERF_SOURCE="$raw_source" RAWMASTER_INTERACTIVE_PERF_OUTPUT="$report_dir/interactive" \
  python3 scripts/run-performance-command.py --timeout 300 --log "$report_dir/interactive.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.EditingInteractivePerformanceTests" "$test_products/RAWMasterImagingTests.xctest" || failures+=(interactive-sequence)
interactive_checker_args=("$report_dir/interactive/interactive-performance.json" --output "$report_dir/interactive-comparison.json")
if (( measure_only )); then interactive_checker_args+=(--measure-only); fi
if [[ -n "$baseline_dir" ]]; then interactive_checker_args+=(--baseline "${baseline_dir:A}/interactive/interactive-performance.json"); fi
python3 scripts/check-interactive-performance.py "${interactive_checker_args[@]}" || failures+=(interactive-comparison)
print 'Measuring individual parameter changes and verifying the rendered pixels…'
RAWMASTER_FLASHRAW_LIBRARY="${flashraw_library:A}" RAWMASTER_CONTROL_RAW="$raw_source" \
RAWMASTER_CONTROL_REPORT="$report_dir/controls.json" RAWMASTER_CONTROL_SAMPLES=20 RAWMASTER_CONTROL_ONLY='' \
  python3 scripts/run-performance-command.py --timeout 600 --log "$report_dir/controls.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.IndividualControlPerformanceTests/testChangedControlsOnResidentRAW" "$test_products/RAWMasterImagingTests.xctest" || failures+=(control-sequence)
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
print 'Measuring complete sRGB display readback for repeated edits and 20 distinct slider values…'
RAWMASTER_PAIRED_READBACK_RAW="$raw_source" RAWMASTER_PAIRED_READBACK_REPORT="$report_dir/display-readback.json" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/display-readback.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.IndividualControlPerformanceTests/testPairedDisplayReadback" "$test_products/RAWMasterImagingTests.xctest" || failures+=(display-readback)
readback_args=("$report_dir/display-readback.json" --output "$report_dir/display-readback-comparison.json")
if [[ -n "$baseline_dir" && -f "${baseline_dir:A}/display-readback.json" ]]; then
  readback_args+=(--baseline "${baseline_dir:A}/display-readback.json")
fi
python3 scripts/check-display-readback.py "${readback_args[@]}" || failures+=(display-readback-comparison)
print 'Measuring the same full display boundary for the white balance, effects, curves, mixer, grading and detail panels…'
RAWMASTER_PANEL_READBACK_RAW="$raw_source" RAWMASTER_PANEL_READBACK_SET='' RAWMASTER_PANEL_READBACK_ONLY='' \
RAWMASTER_PANEL_READBACK_SETTLED=0 RAWMASTER_PANEL_READBACK_REPORT="$report_dir/panel-readback.json" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/panel-readback.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.IndividualControlPerformanceTests/testPanelDisplayReadback" "$test_products/RAWMasterImagingTests.xctest" || failures+=(panel-readback)
panel_args=("$report_dir/panel-readback.json" --output "$report_dir/panel-readback-comparison.json")
if [[ -n "$baseline_dir" && -f "${baseline_dir:A}/panel-readback.json" ]]; then
  panel_args+=(--baseline "${baseline_dir:A}/panel-readback.json")
fi
python3 scripts/check-display-readback.py "${panel_args[@]}" || failures+=(panel-readback-comparison)
print 'Measuring first and final complete photo buffers in one production edit…'
RAWMASTER_PANEL_READBACK_RAW="$raw_source" RAWMASTER_PANEL_READBACK_SET='' RAWMASTER_PANEL_READBACK_ONLY='' \
RAWMASTER_PANEL_READBACK_SETTLED=1 RAWMASTER_PANEL_READBACK_REPORT="$report_dir/panel-schedule.json" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/panel-schedule.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.IndividualControlPerformanceTests/testPanelDisplayReadback" "$test_products/RAWMasterImagingTests.xctest" || failures+=(panel-schedule)
schedule_args=("$report_dir/panel-schedule.json" --output "$report_dir/panel-schedule-comparison.json")
if [[ -n "$baseline_dir" && -f "${baseline_dir:A}/panel-schedule.json" ]]; then
  schedule_args+=(--baseline "${baseline_dir:A}/panel-schedule.json")
fi
python3 scripts/check-display-readback.py "${schedule_args[@]}" || failures+=(panel-schedule-comparison)
print 'Measuring 37 matched photo edits, including LUTs and spatially verified radial masks…'
RAWMASTER_PANEL_READBACK_RAW="$raw_source" RAWMASTER_PANEL_READBACK_SET=photo-operators-v2 RAWMASTER_PANEL_READBACK_ONLY='' \
RAWMASTER_PANEL_READBACK_REPORT="$report_dir/photo-operators-v2.json" \
  python3 scripts/run-performance-command.py --timeout 300 --log "$report_dir/photo-operators-v2.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.IndividualControlPerformanceTests/testPanelDisplayReadback" "$test_products/RAWMasterImagingTests.xctest" || failures+=(photo-operators-v2)
photo_operator_args=("$report_dir/photo-operators-v2.json" --output "$report_dir/photo-operators-v2-comparison.json")
if [[ -n "$baseline_dir" && -f "${baseline_dir:A}/photo-operators-v2.json" ]]; then
  photo_operator_args+=(--baseline "${baseline_dir:A}/photo-operators-v2.json")
fi
python3 scripts/check-display-readback.py "${photo_operator_args[@]}" || failures+=(photo-operators-v2-comparison)
if [[ -n "${RAWMASTER_PERF_LIGHTFLOW_REFERENCE:-}" ]]; then
  python3 scripts/check-lightflow-performance.py "$report_dir" --reference "$RAWMASTER_PERF_LIGHTFLOW_REFERENCE" \
    --output "$report_dir/lightflow-comparison.json" || failures+=(lightflow-comparison)
fi
print 'Measuring source-bound analysis, sampling and the offscreen scopes…'
RAWMASTER_INSPECTION_RAW="$raw_source" RAWMASTER_INSPECTION_REPORT="$report_dir/inspection.json" \
RAWMASTER_INSPECTION_ONLY='' RAWMASTER_INSPECTION_SAMPLES=10 \
  python3 scripts/run-performance-command.py --timeout 300 --log "$report_dir/inspection.log" -- \
  "$xctest_executable" -XCTest "RAWMasterUITests.PhotoInspectionPerformanceTests/testRealRAWAnalysisAndInspection" "$test_products/RAWMasterUITests.xctest" || failures+=(inspection)
inspection_args=("$report_dir/inspection.json" --output "$report_dir/inspection-comparison.json")
if [[ -n "$baseline_dir" && -f "${baseline_dir:A}/inspection.json" ]]; then
  inspection_args+=(--baseline "${baseline_dir:A}/inspection.json")
fi
python3 scripts/check-inspection-performance.py "${inspection_args[@]}" || failures+=(inspection-comparison)
if [[ -n "${RAWMASTER_PERF_CAMERA_JPEG:-}" ]]; then
  print 'Measuring photographic denoising, file formats, shared pixel edges and full TIFF16 exports…'
  rendered_formats="${RAWMASTER_PERF_RENDERED_FORMATS:-}"
  if [[ -z "$rendered_formats" ]]; then
    rendered_formats="$report_dir/photo-denoise-formats"
    python3 scripts/performance/prepare-photo-denoise-formats.py "$RAWMASTER_PERF_CAMERA_JPEG" "$rendered_formats" || failures+=(photo-denoise-fixtures)
  fi
  RAWMASTER_PHOTO_DENOISE_JPEG="$RAWMASTER_PERF_CAMERA_JPEG" RAWMASTER_PHOTO_DENOISE_FORMATS="$rendered_formats" \
  RAWMASTER_PHOTO_DENOISE_REPORT="$report_dir/photo-denoise.json" \
    python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/photo-denoise.log" -- \
    "$xctest_executable" -XCTest "RAWMasterImagingTests.DevelopmentPhotoDenoiseTests" "$test_products/RAWMasterImagingTests.xctest" || failures+=(photo-denoise)
  photo_denoise_args=("$report_dir/photo-denoise.json" --output "$report_dir/photo-denoise-comparison.json")
  if [[ -n "$baseline_dir" ]]; then
    photo_denoise_args+=(--baseline "${baseline_dir:A}/photo-denoise.json")
  fi
  python3 scripts/check-photo-denoise-performance.py "${photo_denoise_args[@]}" || failures+=(photo-denoise-comparison)
fi
if [[ -n "${RAWMASTER_PERF_OUTPUT_DNG:-}" || -n "${RAWMASTER_PERF_SCENE_DNG:-}" ]]; then
  print 'Measuring output-referred DNG and checking a scene-referred control…'
  if [[ -f "${RAWMASTER_PERF_OUTPUT_DNG:-}" && -f "${RAWMASTER_PERF_SCENE_DNG:-}" ]]; then
    RAWMASTER_OUTPUT_DNG="$RAWMASTER_PERF_OUTPUT_DNG" RAWMASTER_SCENE_DNG="$RAWMASTER_PERF_SCENE_DNG" \
    RAWMASTER_OUTPUT_DNG_REPORT="$report_dir/output-referred-dng.json" RAWMASTER_PHOTO_DENOISE_JPEG="${RAWMASTER_PERF_CAMERA_JPEG:-}" \
      python3 scripts/run-performance-command.py --timeout 120 --log "$report_dir/output-referred-dng.log" -- \
      "$xctest_executable" -XCTest "RAWMasterImagingTests.DevelopmentPhotoDenoiseTests/testOutputReferredDNG" "$test_products/RAWMasterImagingTests.xctest" || failures+=(output-referred-dng)
    dng_args=("$report_dir/output-referred-dng.json" --output "$report_dir/output-referred-dng-comparison.json")
    if [[ -n "$baseline_dir" ]]; then dng_args+=(--baseline "${baseline_dir:A}/output-referred-dng.json"); fi
    python3 scripts/check-output-dng-performance.py "${dng_args[@]}" || failures+=(output-referred-dng-comparison)
  else
    failures+=(output-referred-dng-fixtures)
  fi
fi
print 'Checking the trained 2× path on a full sensor, including preview and complete TIFF16…'
RAWMASTER_SUPER_RES_RAW="$raw_source" RAWMASTER_SUPER_RES_REPORT="$report_dir/super-resolution.json" \
  python3 scripts/run-performance-command.py --timeout 540 --log "$report_dir/super-resolution.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.DevelopmentSuperResolutionTests" "$test_products/RAWMasterImagingTests.xctest" || failures+=(super-resolution)
super_args=("$report_dir/super-resolution.json" --output "$report_dir/super-resolution-comparison.json")
if [[ -n "$baseline_dir" ]]; then super_args+=(--baseline "${baseline_dir:A}/super-resolution.json"); fi
python3 scripts/check-super-resolution-performance.py "${super_args[@]}" || failures+=(super-resolution-comparison)
if [[ -n "${RAWMASTER_PERF_NEURAL_RAW:-}" ]]; then
  print 'Verifying learned RAW denoise on the compatible mosaic and exporting a native TIFF…'
  RAWMASTER_AI_DENOISE_RAW="$RAWMASTER_PERF_NEURAL_RAW" RAWMASTER_AI_DENOISE_EXPORT=1 RAWMASTER_AI_DENOISE_REPORT="$report_dir/raw9-denoise.json" \
    python3 scripts/run-performance-command.py --timeout 300 --log "$report_dir/raw9.log" -- \
    "$xctest_executable" -XCTest "RAWMasterImagingTests.DevelopmentNeuralRaw9Tests/testAdmittedMosaicAmountPixelsCacheAndFullTIFF" "$test_products/RAWMasterImagingTests.xctest" || failures+=(raw9)
  raw9_args=("$report_dir/raw9-denoise.json" --output "$report_dir/raw9-denoise-comparison.json")
  if [[ -n "$baseline_dir" ]]; then raw9_args+=(--baseline "${baseline_dir:A}/raw9-denoise.json"); fi
  python3 scripts/check-raw9-performance.py "${raw9_args[@]}" || failures+=(raw9-comparison)
fi
print 'Verifying source-derived depth and its full-size export…'
RAWMASTER_SCENE_DEPTH_RAW="$raw_source" RAWMASTER_SCENE_DEPTH_REPORT="$report_dir/scene-depth.json" \
  python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/scene-depth.log" -- \
  "$xctest_executable" -XCTest "RAWMasterImagingTests.DevelopmentSceneDepthTests/testSceneDepthOnRealRAWAndReopenedRecipe" "$test_products/RAWMasterImagingTests.xctest" || failures+=(scene-depth)
[[ -s "$report_dir/scene-depth.json" ]] || failures+=(scene-depth-evidence)
if [[ -n "${RAWMASTER_PERF_XTRANS_RAW:-}" ]]; then
  print 'Checking Bayer and X-Trans RAW Details with 16-bit TIFF export…'
  RAWMASTER_RAW_DETAILS_BAYER="$raw_source" RAWMASTER_RAW_DETAILS_XTRANS="$RAWMASTER_PERF_XTRANS_RAW" \
  RAWMASTER_RAW_DETAILS_EXPORT=1 RAWMASTER_RAW_DETAILS_OUTPUT="$report_dir/raw-details.json" \
    python3 scripts/run-performance-command.py --timeout 180 --log "$report_dir/raw-details.log" -- \
    "$xctest_executable" -XCTest "RAWMasterImagingTests.DevelopmentRawDetailsImageTests/testRealBayerAndXTransMetadataDispatchPreviewAndExport" "$test_products/RAWMasterImagingTests.xctest" || failures+=(raw-details)
  [[ -s "$report_dir/raw-details.json" ]] || failures+=(raw-details-evidence)
fi
checker_args=("$report_dir")
if (( background_only )); then checker_args+=(--background); fi
if (( measure_only )); then checker_args+=(--measure-only); fi
if [[ -n "$baseline_dir" ]]; then checker_args+=(--baseline-dir "${baseline_dir:A}"); fi
for failed_stage in "${failures[@]}"; do checker_args+=(--failed-stage "$failed_stage"); done
if ! python3 scripts/check-image-performance.py "${checker_args[@]}"; then
  print -u2 "Release regression failed. Reports: $report_dir"
  exit 1
fi
if (( ${#failures} )); then print -u2 "Failed checks: ${failures[*]}"; exit 1; fi
print "Performance reports: $report_dir"
