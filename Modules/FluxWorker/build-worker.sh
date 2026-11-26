#!/bin/sh
set -eu
crate_root=$1
cargo_target=$2
artifact=$3
cargo_bin=${CARGO:-cargo}
if ! command -v "$cargo_bin" >/dev/null 2>&1; then
    cargo_bin="$HOME/.cargo/bin/cargo"
fi
if [ ! -x "$cargo_bin" ] && ! command -v "$cargo_bin" >/dev/null 2>&1; then
    echo "Rust Cargo is required to build the FLUX worker." >&2
    exit 1
fi
# SwiftPM plugins have no network. This script runs before swift build, so it can
# populate the MLX CMake sources on a first checkout; later builds use the cache.
if ! "$cargo_bin" build --offline --locked --release --jobs 4 --manifest-path "$crate_root/Cargo.toml" --target-dir "$cargo_target"; then
    echo "Cached Rust/MLX sources are incomplete; retrying with network for the first build..." >&2
    "$cargo_bin" build --locked --release --jobs 4 --manifest-path "$crate_root/Cargo.toml" --target-dir "$cargo_target"
fi
cp "$cargo_target/release/flux-worker" "$artifact.tmp"
chmod 755 "$artifact.tmp"
metallib=$(strings "$artifact.tmp" | grep -E '/mlx\.metallib$' | tail -1 || true)
if [ -z "$metallib" ] || [ ! -f "$metallib" ]; then
    echo "Missing the precompiled MLX metallib for the FLUX worker." >&2
    exit 1
fi
cp "$metallib" "$(dirname "$artifact")/mlx.metallib"
if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/codesign --force --sign - "$artifact.tmp" >/dev/null 2>&1 || true
fi
mv -f "$artifact.tmp" "$artifact"
