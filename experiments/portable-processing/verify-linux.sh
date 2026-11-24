#!/usr/bin/env bash
# Reuse the same library from a headless Linux process. Fresh results; source mounts are read-only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
state="$root/output/035"
mkdir -p "$state/linux-cargo-registry"
mode=${1:-cpu}
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in cpu|vulkan|batch|raw|production-raw) ;; *) echo 'expected cpu, vulkan, batch, raw or production-raw' >&2; exit 2 ;; esac
result=$(mktemp -d "$state/linux-$mode.XXXXXX")
engine="rust@sha256:ade39a710ef85f3506cffcfec3e8a24ba090badef1dff2fb798f71d878833fea"
mounts=(--mount "type=bind,source=$root,target=/repo,readonly"
        --mount "type=bind,source=$state,target=/state"
        --mount "type=bind,source=$result,target=/results"
        --mount "type=bind,source=$state/linux-cargo-registry,target=/usr/local/cargo/registry")
work_args=("$mode")
if [[ "$mode" == batch ]]; then
    [[ $# -gt 0 ]] || { echo 'batch requires Swift host receipt directories' >&2; exit 2; }
    i=0
    for path in "$@"; do
        source_dir=$(cd "$path" && pwd)
        mounts+=(--mount "type=bind,source=$source_dir,target=/input/$i,readonly")
        work_args+=("/input/$i")
        i=$((i+1))
    done
elif [[ "$mode" == raw || "$mode" == production-raw ]]; then
    [[ $# == 1 && -f "$1" ]] || { echo 'raw requires the Spec 027 Sony fixture' >&2; exit 2; }
    photo=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
    mounts+=(--mount "type=bind,source=$photo,target=/input.ARW,readonly")
fi
docker run --rm "${mounts[@]}" -e CARGO_TARGET_DIR=/state/linux-image-target \
    -w /repo/experiments/portable-processing/image "$engine" sh -ec '
    case "$1" in
    cpu)
        cargo test --release --locked --no-default-features
        cargo run --release --locked --no-default-features --bin image-probe -- cpu 257 131 5 > /results/run.json ;;
    vulkan)
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends mesa-vulkan-drivers libvulkan1
        export XDG_RUNTIME_DIR=/tmp
        cargo test --release --locked -- --include-ignored
        cargo run --release --locked --bin image-probe -- compare 257 131 3 > /results/run.json ;;
    batch)
        shift
        cargo run --release --locked --no-default-features --bin batch-replay -- \
            examples/local-look.json /results/pixels "$@" > /results/run.json ;;
    raw|production-raw)
        echo "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c  /input.ARW" | sha256sum -c -
        archive=/repo/output/tools/flashraw-0.3.1.tar.gz
        if [ ! -r "$archive" ]; then
            archive=/tmp/flashraw.tar.gz
            curl -fsSL --retry 2 https://codeload.github.com/ybouane/flashraw/tar.gz/2994e8c550bec70ab78a938ab28a74d7762124f4 -o "$archive"
        fi
        echo "0243cec068020465819ed2db41f20225235c2f182f010deefcebabd9c4361076  $archive" | sha256sum -c -
        mkdir /tmp/flashraw
        tar -xzf "$archive" -C /tmp/flashraw --strip-components=1
        cargo build --locked --release --manifest-path /tmp/flashraw/Cargo.toml -p flashraw-capi \
            --no-default-features --target-dir /state/linux-flashraw-target
        if [ "$1" = production-raw ]; then
            cargo build --release --locked --no-default-features --manifest-path /repo/Modules/ImageEdit/Cargo.toml
            set -- -DRAWMASTER_PRODUCTION -I/repo/Modules/ImageEdit/include -lrawmaster_image
        else
            cargo build --release --locked --no-default-features
            set -- -Iinclude -lrawmaster_image_poc
        fi
        cc -std=c11 -O2 -I/repo/Sources/CFlashRaw/include /repo/Sources/CFlashRaw/CFlashRaw.c \
            examples/raw-ingress.c -L/state/linux-image-target/release -Wl,-rpath,/state/linux-image-target/release \
            "$@" -ldl -lm -o /tmp/raw-ingress
        /tmp/raw-ingress /input.ARW /state/linux-flashraw-target/release/libflashraw_capi.so \
            /results/crop.rgba32fle > /results/run.json
        sha256sum /results/crop.rgba32fle ;;
    esac
    ' sh "${work_args[@]}"
cat "$result/run.json"
printf '%s\n' "$result"
