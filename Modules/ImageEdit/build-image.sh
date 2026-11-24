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
    echo "Rust Cargo is required to build the image core." >&2
    exit 1
fi
case "$(uname -s)" in
    Darwin) library=librawmaster_image.dylib ;;
    Linux) library=librawmaster_image.so ;;
    *) echo "Unsupported image core build platform" >&2; exit 1 ;;
esac
"$cargo_bin" build --locked --release --jobs 3 --manifest-path "$crate_root/Cargo.toml" --target-dir "$cargo_target"
cp "$cargo_target/release/$library" "$artifact.tmp"
if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/install_name_tool -id '@rpath/librawmaster_image.dylib' "$artifact.tmp"
    /usr/bin/codesign --force --sign - "$artifact.tmp"
fi
mv -f "$artifact.tmp" "$artifact"
