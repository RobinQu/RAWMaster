# Offline JPEG sequence regression and quality evaluation

The six fixture cases contain 1,265 derivative JPEG assets. Default `swift test` uses bundled resources only: actual JPEG bytes → verified SHA-256 → native `SequenceCaptureReader` → observation preprocessor → detector → strict Core validation. It checks per-frame EXIF roundtrip, upright dimensions, provenance integrity, original asset order and separate DJI DNG/JPG identities. Sidecar metadata never repairs detector input.

Human labels live in `SequenceGrouping/v1/truth`. Approved behavior lives in `SequenceGrouping/v1/baselines/behavior-v1.json`. The first JPEG result is measured after conversion; it is not assumed to equal RAW output. Default regression compares current outputs and quality metrics with this approved behavior. A regression pass means that behavior is unchanged, even when human-label quality is unmet.

Run the separate full quality gate from the repository:

```sh
scripts/sequence-fixture-quality.sh
```

Its exit status is **0** for accepted quality, **2** for a completed, integrity-checked evaluation with unmet human quality, and **1** for compilation, execution, dataset integrity, behavior drift or invalid-report errors. It requires a fresh run-ID-bound report; a stale report cannot turn a failed run into an expected quality failure. Set `RAWMASTER_SEQUENCE_FIXTURE_REPORT` to select the report destination. CI should tolerate only status 2 and display that quality remains unmet.

The gate reuses the reviewed Probe evaluator: full-manifest adjacent-edge-v2, precision/recall ≥0.95, typed coverage ≥0.8, exact whole membership and type 1, zero known negative merges and zero unknown negative decisions. Minimum confirmed negative support remains two, except the existing interval427 case requires one. Missing boundary evidence is reported separately from classification failures. DJI0188 remains unknown, and the known 374 positive format-assets do not establish the complete group endpoint. These fixtures are development material, not independent held-out acceptance data.

Only an explicit first-baseline/review workflow records a candidate:

```sh
RAWMASTER_SEQUENCE_FIXTURE_SWIFT_VERSION="$(swift --version)" \
RAWMASTER_SEQUENCE_FIXTURE_RECORD_CANDIDATE="$PWD/output/validation/jpeg-behavior-candidate.json" \
RAWMASTER_SEQUENCE_FIXTURE_REPORT="$PWD/output/validation/jpeg-candidate-report.json" \
swift test --filter SequenceFixtureRegressionTests/testFullOfflineDataset
```

This writes an **unapproved** candidate outside fixtures and never changes human labels or an existing baseline. Review native metadata/integrity, JPEG-vs-RAW drift, quality failures and reference OS/toolchain/decoder before manually approving a baseline. Candidate recording and strict quality mode cannot be combined. Ordinary test runs never rewrite a golden.

Reports preserve current and reference platform evidence. A different macOS/decoder still runs the complete pipeline and compares behavior; a difference requires investigation and review, never a silent refresh or a platform-based skip. Repeatability on one Mac or macOS CI does not establish all supported hardware or decoder versions.
