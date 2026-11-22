# MaskAI Native Validation Module

Standalone macOS arm64 validation of the model routing recovered from Lightflow's `2d41ab1` release. This package does not link to RAWMaster and does not modify its recipe or renderer.

- Native Swift library and CLI.
- ONNX Runtime 1.27.0 C API, pinned by SHA-256.
- Lightflow ONNX models, pinned by the release manifest hashes.
- Subject/background, ADE20K landscape groups, prompted objects, and people/parts.
- Offline unit tests plus opt-in model integration tests.

Run `Scripts/download-dependencies.sh` before model tests. Downloaded binaries and validation outputs are ignored by Git.

## Build and test

```bash
cd experiments/MaskAI
Scripts/install-runtime.sh
Scripts/download-dependencies.sh
Scripts/download-fixtures.sh
swift test
MASK_AI_MODEL_TESTS=1 swift test
```

The default suite runs offline. Model integration tests remain skipped unless `MASK_AI_MODEL_TESTS=1` is present.

## CLI examples

```bash
swift run mask-ai-probe capabilities
swift run mask-ai-probe inspect slimsam-decoder
swift run mask-ai-probe subject Fixtures/Downloaded/car.png Validation/Tests/subject.png
swift run mask-ai-probe landscape sky Fixtures/Downloaded/mountain-lake.jpg Validation/Tests/sky.png
swift run mask-ai-probe object Fixtures/Downloaded/car.png Validation/Tests/object.png 0.5,0.5
swift run mask-ai-probe people entirePerson Fixtures/Downloaded/messi5.jpg Validation/Tests/person.png 0
```

## Validation caveats

- ADE20K has no snow label; snow uses an explicitly marked terrain/color compatibility experiment.
- The Q8 SlimSAM box-only path selected background in the initial validation. Rectangle prompts therefore add a center positive point and record `addedBoxCenter=true`.
- Teeth use inner-mouth geometry plus a color prior; an empty result is expected for a closed mouth with no visible teeth.
- PNG generation and non-empty coverage are execution evidence, not a claim of Adobe-equivalent segmentation quality.

## Real RAW validation

Copy selected RAW inputs into the ignored `Fixtures/RAW` directory, then run:

```bash
MASK_AI_RAW_TESTS=1 swift test --filter RAWIntegrationTests
```

The RAW suite writes source metadata, masks, actual +0.75 EV effect images, native-resolution crop results, and structured metrics into `Validation/RAW`. It uses an independent CIRAWFilter and validation-only effect renderer; it does not call or modify RAWMaster production code.

## Independent service and performance acceptance

The module also includes semantic descriptors, immutable snapshot storage, a serialized async coordinator, native RunOptions cancellation, cancellation rollback, and explicit model/cache release.

```bash
MASK_AI_MODEL_TESTS=1 swift test --filter CoordinatorTests
MASK_AI_PERFORMANCE_TESTS=1 swift test --filter PerformanceAcceptanceTests
```

The performance test deletes its own snapshot directory before starting, so cold operations cannot accidentally reuse an earlier benchmark's results. Results are written to `Validation/Performance/performance-results.json`.
