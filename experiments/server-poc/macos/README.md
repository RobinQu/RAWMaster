# macOS reference helper (PoC only)

These two files are **not** part of the production target. They were copied into an isolated
Git worktree at `5991372` under `~/Downloads/rawmaster-poc-20261127/RAWMaster` to produce the
60MP macOS reference for P1/P2.

## Apply in the isolated worktree

```sh
cp DevelopmentScenePOCDiagnostics.swift \
  "$WORKTREE/Sources/RAWMasterImaging/"
cp ScenePOC.swift \
  "$WORKTREE/Sources/RAWMasterDiagnostics/"
```

Add the dispatch in `Sources/RAWMasterDiagnostics/RAWMasterDiagnostics.swift` immediately
after the existing `--scene-hdr-avif` block:

```swift
if arguments.first == "--scene-poc" {
    exit(try ScenePOC.run(arguments))
}
```

Build and run:

```sh
cd "$WORKTREE"
swift build -c release --product RAWMasterDiagnostics -j 16
export RAWMASTER_FLASHRAW_LIBRARY=/path/to/libflashraw_capi.dylib
.build/release/RAWMasterDiagnostics --scene-poc \
  DSC00413.ARW scene-60mp-v1.json scene-60mp-v2.json mac-run 2048 6442450944
```

The command writes `scene-input.f32`, `scene-output.f32`, `display-sdr.f32`,
`display-hdr.f32`, `scene-macos.avif`, and `receipt.json` into a **new** directory. It refuses
to overwrite an existing non-empty directory and verifies the ARW SHA-256 before/after.

## Host-specific build workarounds

The isolated worktree was built over SSH, where the SwiftPM build-tool plugin environment did
not include `HOME`, the Homebrew bin path, or `rustc`. The worktree's four
`Modules/*/build-*.sh` scripts were patched locally (not in this repository) to:

```sh
if [ -z "${HOME:-}" ]; then HOME=/Users/robinqu; export HOME; fi
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
if [ -z "${RUSTC:-}" ] && [ -x "$HOME/.cargo/bin/rustc" ]; then
  RUSTC="$HOME/.cargo/bin/rustc"; export RUSTC
fi
```

A symlink `~/.cargo/bin/cargo -> ~/.rustup/toolchains/nightly-aarch64-apple-darwin/bin/cargo`
was also created. These are environment fixes, not product changes.

## What it reuses

- `DevelopmentSceneRAWV1` for real ARW → AP1 F32.
- `DevelopmentSceneGraphRendererV1` with `RAWMASTER_SCENE_BACKEND=rust`.
- `DevelopmentSceneOutputV1` ACES 2 SDR/HDR delivery.
- `DevelopmentSceneAVIFV1` ImageIO HDR AVIF encoder.

It does not add production UI, queue wiring, or a new batch model.
