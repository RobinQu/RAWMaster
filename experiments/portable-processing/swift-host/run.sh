#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
build="$root/output/035"
mkdir -p "$build"
image="$root/experiments/portable-processing/image"
catalog="$root/experiments/portable-processing/catalog"
for crate in image catalog; do
    cargo build --locked --release --manifest-path "$root/experiments/portable-processing/$crate/Cargo.toml" --target-dir "$build/$crate-target"
done
result=$(mktemp -d "$build/host.XXXXXX")
export RM035_ROOT="$root" RM035_RESULT="$result"
export RM035_PHOTO="${1:-$root/specs/030-ai-retouching/evidence/mountain-lake.jpg}"
export RM035_MASK="${2:-$root/specs/035-portable-processing-cores/evidence/sky-mask.png}"
swift test --scratch-path "$build/swift-build" -j 10 \
    -Xswiftc -I -Xswiftc "$image/include" -Xswiftc -I -Xswiftc "$catalog/include" \
    -Xlinker -L"$build/image-target/release" -Xlinker -lrawmaster_image_poc \
    -Xlinker -L"$build/catalog-target/release" -Xlinker -lrmq_probe \
    -Xlinker -rpath -Xlinker "$build/image-target/release" \
    -Xlinker -rpath -Xlinker "$build/catalog-target/release" \
    --filter PortableProcessing035Tests
test -s "$result/worker.json" && test -s "$result/canvas.png"
printf '%s\n' "$result"
