#!/bin/bash
# Build the self-contained macOS helper. OpenCV is static; no package-manager libraries are loaded at runtime.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != "--verify-kernels" ]; }; then echo "usage: build.sh OUTPUT_EXECUTABLE [--verify-kernels]" >&2; exit 64; fi
root="$(cd "$(dirname "$0")" && pwd)"
out="$1"
target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
arch="${RAWMASTER_RENDER_ARCH:-$(uname -m)}"
cache="${RAWMASTER_RENDER_CACHE_DIR:-${TMPDIR:-/tmp}/rawmaster-render-4.12.0-$arch}"
prefix="${RAWMASTER_OPENCV_PREFIX:-$cache/opencv}"
mkdir -p "$cache" "$(dirname "$out")"
if [ ! -f "$prefix/lib/libopencv_calib3d.a" ]; then
    stage="$(mktemp -d "$cache/vendor.XXXXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    curl --fail --silent --show-error --location --retry 2 \
        'https://codeload.github.com/opencv/opencv/tar.gz/refs/tags/4.12.0' -o "$stage/opencv.tar.gz"
    (cd "$stage" && echo '44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d  opencv.tar.gz' | shasum -a 256 -c -)
    tar -xzf "$stage/opencv.tar.gz" -C "$stage"
    cmake -S "$stage/opencv-4.12.0" -B "$stage/build" \
        -DBUILD_LIST=calib3d,features2d,imgproc -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF \
        -DBUILD_ITT=OFF -DWITH_ITT=OFF -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_LAPACK=OFF \
        -DWITH_ADE=OFF -DBUILD_opencv_gapi=OFF -DWITH_EIGEN=OFF -DWITH_PROTOBUF=OFF -DWITH_CAROTENE=OFF -DWITH_KLEIDICV=OFF \
        -DCV_DISABLE_OPTIMIZATION=ON -DENABLE_LTO=OFF -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$target" -DCMAKE_INSTALL_PREFIX="$stage/prefix"
    cmake --build "$stage/build" --target install --parallel "${RAWMASTER_RENDER_BUILD_JOBS:-4}"
    mkdir -p "$(dirname "$prefix")"
    if [ ! -d "$prefix" ]; then mv "$stage/prefix" "$prefix"; fi
fi
objects="$(mktemp -d "$cache/objects.XXXXXXXX")"
trap 'rm -rf "$objects" "${stage:-}"' EXIT
for unit in Registration RenderPixels FloatTiff; do
    xcrun clang++ -std=c++17 -O3 -arch "$arch" -mmacosx-version-min="$target" \
        -I"$prefix/include/opencv4" -c "$root/$unit.cpp" -o "$objects/$unit.o"
done
xcrun swiftc -parse-as-library -target "$arch-apple-macosx$target" -O -whole-module-optimization \
    -import-objc-header "$root/RenderMath.h" "$root"/*.swift "$objects"/*.o \
    -L"$prefix/lib" -lopencv_calib3d -lopencv_features2d -lopencv_flann -lopencv_imgproc -lopencv_core \
    -lc++ -lz -framework Accelerate -o "$objects/rawmaster-group-render"
install -m 755 "$objects/rawmaster-group-render" "$out"

if [ "${2:-}" = "--verify-kernels" ]; then
    xcrun clang++ -std=c++17 -O2 -arch "$arch" -I"$prefix/include/opencv4" \
        "$root/../tests/group_render_math.cpp" "$objects"/*.o -L"$prefix/lib" \
        -lopencv_calib3d -lopencv_features2d -lopencv_flann -lopencv_imgproc -lopencv_core \
        -lz -framework Accelerate -framework Foundation -o "$objects/kernel-test"
    "$objects/kernel-test"
fi
