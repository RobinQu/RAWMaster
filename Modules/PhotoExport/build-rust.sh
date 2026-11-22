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
    echo "Install Cargo and CMake to build the Rust export library." >&2
    exit 1
fi
"$cargo_bin" build --locked --release --lib --jobs 4 --manifest-path "$crate_root/Cargo.toml" --target-dir "$cargo_target"
case "$(uname -s)" in
    Darwin)
        cp "$cargo_target/release/librawmaster_photo_export.dylib" "$artifact.tmp"
        /usr/bin/install_name_tool -id '@rpath/librawmaster_photo_export.dylib' "$artifact.tmp"
        /usr/bin/codesign --force --sign - "$artifact.tmp"
        ;;
    Linux) cp "$cargo_target/release/librawmaster_photo_export.so" "$artifact.tmp" ;;
    *) echo "Unsupported export build platform" >&2; exit 1 ;;
esac
mv -f "$artifact.tmp" "$artifact"
