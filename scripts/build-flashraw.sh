#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

commit="2994e8c550bec70ab78a938ab28a74d7762124f4"
archive_sha="0243cec068020465819ed2db41f20225235c2f182f010deefcebabd9c4361076"
tools="$PWD/output/tools"
source_dir="${FLASHRAW_SOURCE_DIR:-$tools/flashraw-src}"
target_dir="${FLASHRAW_TARGET_DIR:-$tools/flashraw-target}"

if [[ ! -f "$source_dir/Cargo.toml" ]]; then
  archive="$tools/flashraw-0.3.1.tar.gz"
  if [[ ! -f "$archive" ]]; then
    mkdir -p "$tools"
    curl -fL --max-time 300 "https://codeload.github.com/ybouane/flashraw/tar.gz/$commit" -o "$archive"
  fi
  actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual_sha" == "$archive_sha" ]] || { print -u2 "FlashRaw archive SHA-256 mismatch"; exit 1; }
  mkdir -p "$source_dir"
  tar -xzf "$archive" -C "$source_dir" --strip-components 1
fi

if [[ -n "${CARGO:-}" ]]; then
  cargo_command="$CARGO"
elif command -v cargo >/dev/null 2>&1; then
  cargo_command="$(command -v cargo)"
else
  cargo_command="$tools/rustup-home/toolchains/stable-aarch64-apple-darwin/bin/cargo"
fi
if [[ ! -x "$cargo_command" ]]; then
  print -u2 "Rust cargo is required. Set CARGO to an existing Rust 1.87+ toolchain."
  exit 1
fi
export PATH="${cargo_command:h}:$PATH"

export CARGO_HOME="${CARGO_HOME:-$tools/cargo-home}"
"$cargo_command" build --locked --manifest-path "$source_dir/Cargo.toml" --release -p flashraw-capi --features gpu,jpegxl --target-dir "$target_dir"
library="$target_dir/release/libflashraw_capi.dylib"
if [[ ! -f "$library" ]]; then
  print -u2 "Missing built FlashRaw library: $library"
  exit 1
fi
print "Built $library"
print "Build the app with FLASHRAW_LIBRARY='$library' scripts/build-app.sh release"
