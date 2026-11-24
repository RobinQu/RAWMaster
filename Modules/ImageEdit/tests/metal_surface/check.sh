#!/bin/sh
# Run from any directory on a Metal Mac. Python with Pillow prepares the real frozen fixture.
# Usage: PYTHON=/path/to/python3 ./check.sh OUTPUT_DIR
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: check.sh OUTPUT_DIR" >&2
    exit 2
fi
mkdir -p "$1"
artifacts=$(cd "$1" && pwd)
crate_root=$(cd "$(dirname "$0")/../.." && pwd)
catalog="$crate_root/../../Sources/RAWMasterImaging/Resources/PhotoFilters"
cargo_bin=${CARGO:-cargo}
python_bin=${PYTHON:-python3}
target_dir=${CARGO_TARGET_DIR:-"$artifacts/cargo"}
"$python_bin" "$crate_root/tests/replay_mask.py" prepare "$artifacts/inputs"
RAWMASTER_METAL_INPUTS="$artifacts/inputs" RAWMASTER_METAL_REPORT="$artifacts/dag.json" \
    "$cargo_bin" test --locked --manifest-path "$crate_root/Cargo.toml" --target-dir "$target_dir" \
        --features surface-fence-probe --test metal_surface_replay -- --include-ignored --nocapture --test-threads=1
"$cargo_bin" build --locked --manifest-path "$crate_root/Cargo.toml" --target-dir "$target_dir"
mkdir -p "$artifacts/lib"
cp "$target_dir/debug/librawmaster_image.dylib" "$artifacts/lib/librawmaster_image.dylib"
/usr/bin/install_name_tool -id @rpath/librawmaster_image.dylib "$artifacts/lib/librawmaster_image.dylib"
/usr/bin/codesign --force --sign - "$artifacts/lib/librawmaster_image.dylib"
xcrun clang -Werror -fobjc-arc -framework Foundation -framework Metal -framework IOSurface \
    -framework CoreImage -framework CoreGraphics -framework CoreVideo -I"$crate_root/include" \
    "$crate_root/tests/metal_surface/c_abi.m" "$crate_root/tests/metal_surface/native.m" \
    -L"$artifacts/lib" -lrawmaster_image -Wl,-rpath,@executable_path/lib -o "$artifacts/c_abi"
"$artifacts/c_abi" "$catalog" > "$artifacts/c_abi.json"
