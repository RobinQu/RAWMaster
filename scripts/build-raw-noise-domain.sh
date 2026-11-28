#!/bin/zsh
set -euo pipefail

resources="${1:A}"
source_file="$resources/RawNoiseDomain.metal"
test -f "$source_file"
rm -f -- "$resources/RawNoiseDomain.metallib" "$resources/RawNoiseDomain.json"
if ! compiler_version=$(xcrun -sdk macosx metal --version 2>/dev/null); then
  print -u2 'Metal toolchain unavailable. This build uses the original RAW noise validation.'
  exit 0
fi

work=$(mktemp -d "$resources/.raw-noise-domain.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
xcrun -sdk macosx metal -c -std=metal3.1 "$source_file" -o "$work/RawNoiseDomain.air"
xcrun -sdk macosx metal -framework CoreImage "$work/RawNoiseDomain.air" -o "$work/RawNoiseDomain.metallib"
sdk_version=$(xcrun -sdk macosx --show-sdk-version)
python3 - "$source_file" "$work" "$compiler_version" "$sdk_version" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys

source, work = (Path(path) for path in sys.argv[1:3])
record = {
    "schemaVersion": 1,
    "function": "checkedNoiseInputs",
    "sourceSHA256": sha256(source.read_bytes()).hexdigest(),
    "librarySHA256": sha256((work / "RawNoiseDomain.metallib").read_bytes()).hexdigest(),
    "compiler": sys.argv[3],
    "sdkVersion": sys.argv[4],
    "compileFlags": ["-c", "-std=metal3.1"],
    "linkFlags": ["-framework", "CoreImage"],
}
(work / "RawNoiseDomain.json").write_text(json.dumps(record, indent=2) + "\n")
PY
mv "$work/RawNoiseDomain.metallib" "$work/RawNoiseDomain.json" "$resources/"
