#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 PRODUCT_DYLIB MODE6_REFERENCE_PROBE_DYLIB" >&2
    exit 2
fi
src=$(CDPATH='' cd "$(dirname "$0")" && pwd)
bridge="$src/../../Bridge"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang -O2 -fobjc-arc -Wall -Werror -I"$bridge/include" -framework Metal -framework Foundation \
    "$src/product.m" "$bridge/ImageEditLoader.c" -o "$work/check"
"$work/check" "$1" "$2"
