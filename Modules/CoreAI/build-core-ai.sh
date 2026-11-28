#!/bin/sh
set -eu
crate_root=$1
cargo_target=$2
artifact=$3
cargo_bin=${CARGO:-cargo}
if ! command -v "$cargo_bin" >/dev/null 2>&1; then
    cargo_bin="$HOME/.cargo/bin/cargo"
fi
if ! command -v "$cargo_bin" >/dev/null 2>&1; then
    echo 'Rust Cargo is required to build CoreAI.' >&2
    exit 1
fi

if [ "$(uname -s)" != Darwin ]; then
    echo 'The bundled CoreAI runtime currently targets macOS.' >&2
    exit 1
fi

if ! "$cargo_bin" build --offline --locked --release --jobs 3 --manifest-path "$crate_root/Cargo.toml" --target-dir "$cargo_target"; then
    echo 'CoreAI builds offline. Prepare the pinned dependencies with scripts/fetch-rust-dependencies.sh.' >&2
    exit 1
fi
cp "$cargo_target/release/librawmaster_core_ai.dylib" "$artifact.tmp"
/usr/bin/install_name_tool -id '@rpath/librawmaster_core_ai.dylib' "$artifact.tmp"
/usr/bin/codesign --force --sign - "$artifact.tmp"
mv -f "$artifact.tmp" "$artifact"
