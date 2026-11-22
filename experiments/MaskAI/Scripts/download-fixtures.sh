#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Fixtures/Downloaded"
mkdir -p "$OUT"
fetch() {
  local url="$1" name="$2"
  if [[ ! -s "$OUT/$name" ]]; then
    curl --fail --location --retry 2 --output "$OUT/$name.tmp" "$url"
    mv "$OUT/$name.tmp" "$OUT/$name"
  fi
  shasum -a 256 "$OUT/$name"
}
fetch "https://huggingface.co/ybelkada/segment-anything/resolve/main/assets/car.png" "car.png"
fetch "https://raw.githubusercontent.com/opencv/opencv/master/samples/data/lena.jpg" "lena.jpg"
fetch "https://images.unsplash.com/photo-1501785888041-af3ef285b470?auto=format&fit=crop&w=1600&q=90" "mountain-lake.jpg"
fetch "https://images.unsplash.com/photo-1483664852095-d6cc6870702d?auto=format&fit=crop&w=1600&q=90" "snow.jpg"
fetch "https://raw.githubusercontent.com/opencv/opencv/master/samples/data/messi5.jpg" "messi5.jpg"
