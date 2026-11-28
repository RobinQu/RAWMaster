# RAWMaster CoreAI

The Swift package exposes the first Spec 044 inference route. `CoreAI.open()` validates the app seal and loads the fixed arm64 ONNX Runtime 1.27.0 framework. The Intel 0095 model loads lazily and the runtime holds one CPU session. Evict the session when its consumer goes idle. Cancellation retains the borrowed input until the native call returns.

The [C ABI](include/rawmaster_core_ai.h) accepts upright sRGB8 RGBA or BGRA and five full-image landmarks in Discovery order. It returns a unit-normalized 256-float vector. The current embedding operation requires a full-image ROI. Rust owns the 128×128 alignment, tensor layout, inference, and normalization. Swift owns image decoding, orientation, and delivery to the still-current consumer.

From the repository root, prepare the locked dependencies once and build offline.

```sh
scripts/fetch-rust-dependencies.sh
cargo test --offline --locked --release --manifest-path Modules/CoreAI/Cargo.toml
```

The local qualification build accepts `RAWMASTER_CORE_MODELS_DIR` with `manifest.json` matching the [Intel contract](ModelContracts/intel-0095-v1.json), the `face/` model at its declared path, and the pinned ONNX Runtime wheel at the directory root. Supply a fresh `RAWMASTER_APP_OUTPUT`. The build stages the approved files and their notices in `Contents/Resources/CoreModels/v1` and both dynamic libraries in `Contents/Frameworks`.

The separate opt-in native cancellation test accepts `RAWMASTER_COREAI_TEST_CONTENTS` pointing to the staged app's `Contents` folder. Run it with the `cancels_an_attached_native_run_and_reuses_the_joined_session` filter and `-- --ignored`.

This checkpoint qualifies the Intel embedding route with supplied landmarks. Discovery route changes follow detector parity and index migration validation. [Native qualification](../../specs/044-mac-app-store-lite/core-ai-validation.md)
