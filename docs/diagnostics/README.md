# Burst evidence diagnostic

This executable experiment reads only an explicit input manifest. It does not create groups, suggest candidates, update the library, score selection quality, or change source media. The application does not expose it. Its purpose is to inspect EXIF, normalized embedded-preview distances, and prespecified time-only sensitivity baselines before deciding whether a production algorithm has enough evidence.

## Inputs and extraction

The manifest contains one relative source filename per line in the intended source order. It is independent of the label fixture. The reader preserves that order and opaque IDs; chronological IDs are a second view and do not erase clock rollback. Parent traversal, duplicate sources, and source symlinks are rejected. Labels are loaded only after extraction and pair analysis finish. Only explicitly declared negative boundaries count as negative examples.

The strict EXIF parser retains DateTimeOriginal, SubsecTimeOriginal, and OffsetTimeOriginal. Calendar-invalid dates are rejected. Missing or invalid times and fractions remain unknown, never zero. Local camera time differences are not UTC elapsed time. An explicit valid offset is required to construct a UTC instant. Neither folder dates nor file modification times substitute for capture time. Camera model does not establish physical-device identity.

The serial utility reader extracts an orientation-normalized embedded thumbnail with a 160-pixel longest-edge limit. RAW inputs never fall back to full RAW decoding. Feature vectors describe a 32×32 normalized luminance image, three 16-bin sRGB histograms, and a 64-bit difference hash. Reports provide adjacent distances separately; there is no combined confidence, visual threshold, trained model, or production grouping rule.

The managed-memory limit is 64 MiB, with a 512-input limit and an explicit scratch reservation. The report gives a conservative retained-record/vector estimate; this is not a process-RSS or framework-internal allocation guarantee. Work units are serial, use no foreground ImagePipeline permits, and check cancellation before and after each read. A completed uncancellable unit is discarded if cancellation arrived while it ran. Partial, canceled, failed-preview, and budget outcomes retain coverage counts and cannot report complete success. Production foreground scheduling is not validated by this standalone tool.

## Run and fail-fast guard

Build and test without changing application state:

```sh
swift test --filter RAWMasterDiagnosticsTests
swift build --product RAWMasterDiagnostics
```

Before a new independent first read, finish all builds, preserve the executable snapshot, and record its checksum together with the diagnostic source hashes and aggregate checksum. Use that freeze with the execution guard:

```sh
python3 scripts/run-burst-evidence.py \
  --freeze /absolute/path/to/freeze.json \
  --binary /absolute/path/to/frozen/RAWMasterDiagnostics \
  --receipt /absolute/path/to/execution-receipt.json \
  -- --burst-evidence \
  --source-root /absolute/path/to/read-only/source \
  --inputs /absolute/path/to/independent-inputs.txt \
  --labels /absolute/path/to/posthoc-labels.json \
  --output /absolute/path/outside-source/report.json
```

The freeze requires `sourceSHA256` (repository-relative file names to SHA-256), `aggregateSourceSHA256` (sorted filename, NUL, then file bytes), and `binarySHA256`. The guard verifies every value before launch, copies the executable to a private verified snapshot, and runs those verified bytes. A build or source mismatch exits 78 without launching the reader. An execution receipt is provenance evidence, not scientific validation or production acceptance. Never replace a first-read freeze or receipt to hide a failed check; a later replay needs separately named provenance.

The diagnostic CLI exits 0 for complete extraction, 2 for partial/cancelled extraction, and 1 for setup errors. Exit 0 does not accept product quality. Optional `--budget-mib 1...64` and `--cancel-after N` exercise partial outcomes. Labels use `groups:[{id,files}]` and optional `negativeBoundaries:[{from,to}]`. Files outside the explicit manifest are never scanned.

## Frozen experiment, 2026-10-23

Artifacts are under `output/validation/m2a-2026-10-23/` (ignored local evidence):

- `burst-evidence-tests.log`: 16 synthetic tests, including all eight EXIF orientations, strict times/offsets, clock rollback, no RAW fallback, serial reads, cancellation, budget, posthoc labels, unknown coverage, Wilson intervals, and null precision for zero predictions.
- `burst-evidence-123.json` and `.log`: the user-labeled 123-frame single logical episode.
- `burst-evidence-freeze.json`: algorithm version `burst-evidence-experiment-1`, all fixed parameters and four diagnostic source hashes, frozen before independent source reads. Aggregate source SHA-256: `06ae22ef49868eb464be9aa71e92445b523bfb758206cdf058eaeb3741187428`.
- `burst-evidence-independent-16.json` and `.log`: one independent 14-frame positive episode plus its two user-confirmed negative boundaries.
- `burst-evidence-independent-run-receipt.json`: the first independent read's execution limitation. Core tests relinked the executable after freezing; all four diagnostic source hashes and all analysis parameters matched, but the binary was not byte-identical. A shell command continued after the binary precheck failed. That first read is preserved; it is not recorded as a passed execution-guard check.
- `burst-evidence-guard-tests.log`: three synthetic tests of the execution guard added after that execution error. Source or binary mismatch must stop before a stub can write its launch marker; matching bytes execute a private verified snapshot. No independent source reread was needed for this correction.
- `burst-evidence-cli-smoke.json`: real original-scope cancellation after two records exits 2 and records 121 not attempted; a 1 MiB budget exits 2 before any source read.

Both real runs had complete metadata, subsecond local time, and embedded-preview coverage; neither had explicit offsets. The original 123-frame extraction took 2.20 s with a 4.69 MB managed peak estimate. Independent 16-frame extraction took 0.385 s with a 2.43 MB estimate. These are extraction boundaries, not display latency or filesystem-cold performance claims. Both observed camera models were ILCE-1M2. Actual EXIF dates differ from the folder-date hints and are preserved in the reports.

| Prespecified time threshold | Original positive pairs retained | Independent positive pairs retained | Independent negative boundaries falsely joined |
| --- | --- | --- | --- |
| 0.5 s | 119/122 | 13/13 | 0/2 |
| 1 s | 119/122 | 13/13 | 0/2 |
| 2 s | 121/122 | 13/13 | 0/2 |
| 5 s | 121/122 | 13/13 | 1/2 |
| 10 s | 122/122 | 13/13 | 2/2 |

The original positive episode contains a 9.075 s pause. The independent negative boundaries have local camera gaps of 6.606 s and 2.986 s. Raising a pure time window to preserve the original episode also merges those labeled boundaries. No threshold was selected after seeing these results. The preview distances remain descriptive and unchanged.

Even 13/13 has a nominal binomial Wilson 95% lower bound of 77.19%; observing zero errors in two boundaries still leaves a 65.76% upper bound. Adjacent frames are dependent observations, so these reference binomial intervals do not establish confidence over independent scenes, cameras, or shooting modes. Per-threshold precision refers only to predicted joins on the explicitly labeled edges. Zero predicted joins gives null precision and never passes. Unknown positives count as unretained in coverage-aware retention, and unknown boundaries are reported separately.

B2 remains an isolated diagnostic prototype. It has not passed SC04 or production quality acceptance. No frozen time-plus-visual production rule exists, and the independent result cannot be used to claim that a posthoc choice of 2 s passed production acceptance.
