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

opencv_complete() {
    local part
    for part in include/opencv4/opencv2/core/version.hpp include/opencv4/opencv2/calib3d.hpp \
        lib/libopencv_core.a lib/libopencv_calib3d.a lib/libopencv_features2d.a \
        lib/libopencv_flann.a lib/libopencv_imgproc.a; do
        [ -s "$1/$part" ] || return 1
    done
}

cleanup() {
    if [ -n "${cache_lock:-}" ]; then rmdir "$cache_lock"; fi
    if [ -n "${objects:-}" ]; then rm -rf "$objects"; fi
    if [ -n "${stage:-}" ]; then rm -rf "$stage"; fi
}
trap cleanup EXIT

if ! opencv_complete "$prefix"; then
    if [ -n "${RAWMASTER_OPENCV_PREFIX:-}" ]; then
        echo "Incomplete OpenCV 4.12.0 installation at RAWMASTER_OPENCV_PREFIX: $prefix" >&2
        exit 1
    fi
    stage="$(mktemp -d "$cache/vendor.XXXXXXXX")"
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
    if ! opencv_complete "$stage/prefix"; then
        echo "OpenCV 4.12.0 build did not install the required headers and libraries" >&2
        exit 1
    fi
    if mkdir "$cache/opencv-install.lock" 2>/dev/null; then
        cache_lock="$cache/opencv-install.lock"
        if ! opencv_complete "$prefix"; then
            if [ -e "$prefix" ] || [ -L "$prefix" ]; then mv "$prefix" "$stage/incomplete-prefix"; fi
            mv "$stage/prefix" "$prefix"
        fi
        rmdir "$cache_lock"
        unset cache_lock
    fi
    # Another build may be publishing. The verified private installation is already usable.
    if ! opencv_complete "$prefix"; then prefix="$stage/prefix"; fi
fi
objects="$(mktemp -d "$cache/objects.XXXXXXXX")"
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
