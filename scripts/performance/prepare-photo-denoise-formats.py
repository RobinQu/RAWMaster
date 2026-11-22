#!/usr/bin/env python3
"""Build small real-photograph codec fixtures from the supplied camera JPEG."""
import argparse
from pathlib import Path
import shutil
import subprocess


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if not all(shutil.which(tool) for tool in ("magick", "cjxl")):
        raise SystemExit("Install ImageMagick and cjxl, or provide RAWMASTER_PERF_RENDERED_FORMATS containing the seven codec fixtures.")
    args.destination.mkdir(parents=True, exist_ok=False)
    png = args.destination / "camera.png"
    subprocess.run(["magick", str(args.source), "-resize", "384x256!", "-strip", "PNG24:" + str(png)], check=True)
    for extension in ("heic", "avif", "webp", "psd", "psb"):
        output = args.destination / ("camera." + extension)
        subprocess.run(["magick", str(png), extension.upper() + ":" + str(output)], check=True)
    subprocess.run(["cjxl", str(png), str(args.destination / "camera.jxl"),
                    "--distance=0", "--effort=3", "--num_threads=2"], check=True)
