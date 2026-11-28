# RAWMaster CoreAI

The Swift package exposes the Spec 044 YuNet detector and Intel 0095 embedding routes. `CoreAI.open()` validates the app seal and loads the fixed arm64 ONNX Runtime 1.27.0 framework. Both CPU sessions load lazily, and the engine admits one call at a time. Evict the sessions when the consumer goes idle. Cancellation retains the borrowed input until the native call returns.

The [C ABI](include/rawmaster_core_ai.h) accepts upright sRGB8 RGBA or BGRA with a full-image ROI. Detection returns normalized boxes and five landmarks in Discovery order. Embedding takes those landmarks and returns a unit-normalized 256-float vector. Rust owns the detector input, NMS, 128×128 alignment, inference, and normalization. Swift owns image decoding, orientation, and delivery to the still-current consumer.

From the repository root, prepare the locked dependencies once and build offline.

```sh
scripts/fetch-rust-dependencies.sh
cargo test --offline --locked --release --manifest-path Modules/CoreAI/Cargo.toml
```

The local qualification build accepts `RAWMASTER_CORE_MODELS_DIR` with `manifest.json` matching the [Intel contract](ModelContracts/intel-0095-v1.json), the `face/` model at its declared path, and the pinned ONNX Runtime wheel at the directory root. Supply a fresh `RAWMASTER_APP_OUTPUT`. The build stages the approved files and their notices in `Contents/Resources/CoreModels/v1` and both dynamic libraries in `Contents/Frameworks`.

To include detection, add a `detector` field to the manifest equal to the reviewed [YuNet contract](ModelContracts/yunet-2023mar-dynamic-v1.json). Supply the pinned original ONNX, the derived ONNX and its conversion record at the declared input paths. The repository [converter](Tools/derive-yunet.py) emits the latter two. The runtime lazily rejects detection if its model is unavailable, so Intel-only qualification packs continue to work for embedding.

The separate opt-in native cancellation test accepts `RAWMASTER_COREAI_TEST_CONTENTS` pointing to the staged app's `Contents` folder. Run it with the `cancels_an_attached_native_run_and_reuses_the_joined_session` filter and `-- --ignored`.

See the [Intel qualification](../../specs/044-mac-app-store-lite/core-ai-validation.md) and [YuNet qualification](../../specs/044-mac-app-store-lite/core-ai-yunet-validation.md). Discovery route changes follow the frozen library and index migration validation.
