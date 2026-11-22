#!/bin/sh
# From any directory: sh /path/to/catalog/verify.sh macos|linux
set -eu
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd "$here/../../.." && pwd)
module="$repo/Modules/LibraryCatalog"
fixture="$repo/Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg"
case ${1:-} in
    macos)
        out="$repo/output/035-catalog-target"
        mkdir -p "$out"
        cargo build --locked --release --manifest-path "$here/Cargo.toml" --target-dir "$out"
        sh "$module/build-catalog.sh" "$module" "$out/production-build" "$out/production-library.dylib"
        clang -I"$module/Bridge/include" -c "$module/Bridge/LibraryLoader.c" -o "$out/LibraryLoader.o"
        swiftc -I "$here/include" -L "$out/release" -lrmq_probe -lsqlite3 \
            -import-objc-header "$module/Bridge/include/LibraryLoader.h" "$here/CatalogSmoke.swift" \
            "$out/LibraryLoader.o" -o "$out/CatalogSmoke"
        "$out/CatalogSmoke" "$out/production-library.dylib" "$module/src/authority/legacy_v7_reference.sql" "$fixture" > "$out/swift-report.json"
        python3 "$here/verify.py" "$out/release/rmq-probe" > "$out/mac-report.json"
        ;;
    linux)
        out="$repo/output/035-catalog-linux"
        mkdir -p "$out"
        rust_image=rust:1-slim-bookworm@sha256:7c7d4eb4d05b7781187a327809466cfddf29753f6defdc3d19a0e291951b7a37
        python_image=python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72
        # Pre-fetch for the target, then make only the cached registry available to the build container.
        arch=$(docker run --rm "$rust_image" uname -m)
        cargo fetch --locked --manifest-path "$here/Cargo.toml" --target "$arch-unknown-linux-gnu"
        docker run --rm -v "$repo:/work:ro" -v "$out:/out" -v "${CARGO_HOME:-$HOME/.cargo}/registry:/usr/local/cargo/registry:ro" \
            -w /work "$rust_image" cargo build --offline --locked --release --features bundled-sqlite \
            --manifest-path experiments/portable-processing/catalog/Cargo.toml --target-dir /out
        docker run --rm -v "$repo:/work:ro" -w /work "$python_image" python experiments/portable-processing/catalog/verify.py \
            output/035-catalog-linux/release/rmq-probe > "$out/linux-report.json"
        ;;
    *)
        echo 'usage: sh verify.sh macos|linux' >&2
        exit 2
        ;;
esac
echo "Reports in $out"
