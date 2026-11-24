"""Create the alternate 032 native benchmark input set from previously generated fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build(header_source, jpeg_delivery, output):
    jpeg = output / "jpeg-source"
    raw = output / "raw-source"
    output.mkdir()
    jpeg.mkdir()
    raw.mkdir()
    originals = sorted(jpeg_delivery.glob("*.jpg"))
    if len(originals) != 200:
        raise ValueError("expected the 200 JPEGs from the native main-fixture delivery")
    for path in originals:
        shutil.copyfile(path, jpeg / path.name)
    original = header_source.read_bytes()
    if original[:8] != b"II\x2a\x00\x08\x00\x00\x00":
        raise ValueError("expected the 032 little-endian single-strip DNG template")
    count = struct.unpack_from("<H", original, 8)[0]
    tags = {}
    for i in range(count):
        tag, field_type, n, value = struct.unpack_from("<HHII", original, 10 + 12 * i)
        if field_type == 4 and n == 1:
            tags[tag] = value
    width, height = 2400, 1600
    if tags.get(256) != width or tags.get(257) != height or tags.get(279) != width * height * 2 or 273 not in tags:
        raise ValueError("unexpected DNG strip dimensions")
    offset = tags[273]
    if len(original) < offset + width * height * 2:
        raise ValueError("incomplete source DNG")
    rows = [struct.pack(f"<{width}H", *(128 + (x * 3 + y * 37 + (x // 120 % 2) * 700) % 3200
                                         for x in range(width))) for y in range(32)]
    for index in range(20):
        with (raw / f"K{index:03}.dng").open("xb") as dest:
            dest.write(original[:offset])
            for y in range(height):
                dest.write(rows[(2 * index + 3) % 32 if y == 400 + index * 8 else y % 32])
    files = {p.name: {x.name: sha(x) for x in sorted(p.iterdir())} for p in [jpeg, raw]}
    if any(len(names) != len(set(names.values())) for names in files.values()):
        raise ValueError("duplicated inputs")
    (output / "inputs.json").write_text(json.dumps(files, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--jpeg-delivery", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="new, unused directory")
    args = parser.parse_args()
    build(args.template, args.jpeg_delivery, args.output)
