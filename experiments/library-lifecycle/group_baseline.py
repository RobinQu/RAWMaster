# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy==2.2.6", "opencv-python-headless==4.12.0.88", "rawpy==0.26.1"]
# ///
"""Read a camera sequence and write only an aggregate HDR or panorama research report."""

import argparse
import hashlib
import json
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"

import cv2
import numpy as np
import rawpy


SAMPLE_STRIDE = 17
PREVIEW_EDGE = 640


def exif(tool, args):
    result = subprocess.run([tool, *args], capture_output=True, check=False)
    if result.returncode:
        raise ValueError("ExifTool could not read the requested camera tags or preview.")
    return result.stdout


def source_identity(path):
    stat = path.stat()
    if not path.is_file():
        raise ValueError("Each input must be a regular file.")
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns


def frame_preview(tool, path, orientation):
    data = exif(tool, ["-b", "-PreviewImage", str(path)])
    if not data:
        raise ValueError("The input has no embedded PreviewImage.")
    image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
    if image is None:
        raise ValueError("The embedded PreviewImage is unreadable.")
    # The decoder returns stored pixels. Apply the RAW's EXIF orientation once.
    if orientation in (5, 6, 7, 8):
        image = cv2.transpose(image)
    if orientation in (2, 3, 6, 7):
        image = cv2.flip(image, 1)
    if orientation in (3, 4, 7, 8):
        image = cv2.flip(image, 0)
    if orientation not in range(1, 9):
        raise ValueError("The input has an unsupported orientation.")
    height, width = image.shape[:2]
    scale = min(1.0, PREVIEW_EDGE / max(width, height))
    return cv2.resize(image, (max(1, round(width * scale)), max(1, round(height * scale))),
                      interpolation=cv2.INTER_AREA)


def sensor_grid(path):
    with rawpy.imread(str(path)) as raw:
        raw_pattern = raw.raw_pattern
        visible = raw.raw_image_visible
        if raw_pattern is None or raw_pattern.shape != (2, 2) or visible.ndim != 2:
            raise ValueError("The HDR probe supports two-by-two Bayer mosaics.")
        # raw_color uses full-sensor coordinates. Use the actual phase at the visible origin.
        top, left = raw.sizes.top_margin, raw.sizes.left_margin
        phase = np.array([[raw.raw_color(top + y, left + x) for x in range(2)] for y in range(2)])
        ys = np.arange(0, visible.shape[0], SAMPLE_STRIDE)
        xs = np.arange(0, visible.shape[1], SAMPLE_STRIDE)
        channels = phase[(ys % 2)[:, None], (xs % 2)[None, :]]
        blacks = raw.black_level_per_channel
        whites = raw.camera_white_level_per_channel
        black = np.asarray(blacks, dtype=np.float64)[channels]
        white = np.asarray(whites, dtype=np.float64)[channels] if whites else float(raw.white_level)
        if np.any(white <= black):
            raise ValueError("The sensor's black and white levels do not define a valid range.")
        samples = visible[np.ix_(ys, xs)].astype(np.float64)
        levels = np.maximum(0.0, (samples - black) / (white - black))
        shape_and_phase = (visible.shape, tuple(phase.flat), raw.color_desc)
        return levels, shape_and_phase


def exposure(tags):
    try:
        values = tuple(float(tags[key]) for key in ("ExposureTime", "FNumber", "ISO"))
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("The HDR probe requires exposure time, aperture and ISO.") from error
    if not all(math.isfinite(value) and value > 0 for value in values):
        raise ValueError("The HDR exposure tags must be finite and positive.")
    return values


def hdr(paths, metadata, previews):
    settings = [exposure(tags) for tags in metadata]
    if len({(f, iso) for _, f, iso in settings}) != 1:
        raise ValueError("The HDR reference requires constant ISO and aperture.")
    if len({(tags.get("Model"), tags.get("Orientation", 1)) for tags in metadata}) != 1:
        raise ValueError("The HDR reference requires the same camera model and orientation.")
    seconds = [value[0] for value in settings]
    ordered = sorted(range(len(paths)), key=seconds.__getitem__)
    if len(set(seconds)) < 3:
        raise ValueError("The HDR reference needs at least three different shutter times.")
    ref = ordered[len(ordered) // 2]
    shorter = [i for i in ordered if seconds[i] < seconds[ref]]
    longer = [i for i in ordered if seconds[i] > seconds[ref]]
    if not shorter or not longer:
        raise ValueError("The median exposure must have shorter and longer comparison frames.")

    frames = [sensor_grid(path) for path in paths]
    grids = [values for values, _ in frames]
    if len({geometry for _, geometry in frames}) != 1 or len({p.shape for p in previews}) != 1:
        raise ValueError("HDR frames must share sensor geometry, CFA phase and preview dimensions.")
    pairs = []
    for low, high in zip(ordered, ordered[1:]):
        small, large = grids[low], grids[high]
        valid = (small > 0.01) & (small < 0.90) & (large > 0.01) & (large < 0.90)
        count = int(valid.sum())
        med = float(np.median(large[valid] / small[valid])) if count else None
        pairs.append({"shorter_frame": low + 1, "longer_frame": high + 1, "overlap_sites": count,
                      "expected_ratio": seconds[high] / seconds[low], "median_signal_ratio": med})
    valid = [(grid > 0.01) & (grid < 0.90) for grid in grids]
    near_white, low_signal = grids[ref] >= 0.98, grids[ref] < 0.01
    short_coverage = np.logical_or.reduce([valid[i] for i in shorter])
    long_coverage = np.logical_or.reduce([valid[i] for i in longer])
    lumas = [cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) for image in previews]
    mtb = cv2.createAlignMTB(max_bits=4, exclude_range=4, cut=False)
    return {
        "reference_frame": ref + 1, "exposure_seconds": seconds, "iso": settings[ref][2],
        "aperture": settings[ref][1], "sensor_step": SAMPLE_STRIDE, "sensor_sites": grids[ref].size,
        "adjacent_exposures": pairs,
        "reference_near_white": int(near_white.sum()),
        "near_white_covered_by_shorter": int(np.count_nonzero(near_white & short_coverage)),
        "reference_low_signal": int(low_signal.sum()),
        "low_signal_covered_by_longer": int(np.count_nonzero(low_signal & long_coverage)),
        "preview_size": list(reversed(lumas[ref].shape)),
        "preview_median_luma": [float(np.median(gray)) for gray in lumas],
        "preview_integer_shifts": [list(mtb.calculateShift(lumas[ref], gray)) for gray in lumas],
    }


def match_pair(first, second):
    points_a, descriptors_a = first
    points_b, descriptors_b = second
    metrics = {"matches": 0, "inliers": 0, "median_proxy_px": None, "p95_proxy_px": None}
    if descriptors_a is None or descriptors_b is None or len(descriptors_b) < 2:
        return metrics
    neighbors = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(descriptors_a, descriptors_b, k=2)
    matches = [a for a, b in neighbors if a.distance < 0.75 * b.distance]
    metrics["matches"] = len(matches)
    if len(matches) < 4:
        return metrics
    src = np.float32([points_a[m.queryIdx].pt for m in matches])
    dst = np.float32([points_b[m.trainIdx].pt for m in matches])
    transform, mask = cv2.findHomography(src, dst, cv2.RANSAC, 3.0)
    if transform is None or mask is None:
        return metrics
    keep = mask.ravel().astype(bool)
    if keep.any():
        projected = cv2.perspectiveTransform(src[keep, None, :], transform)[:, 0, :]
        errors = np.linalg.norm(projected - dst[keep], axis=1)
        metrics.update(inliers=int(keep.sum()), median_proxy_px=float(np.median(errors)),
                       p95_proxy_px=float(np.quantile(errors, 0.95)))
    return metrics


def panorama(previews):
    orb = cv2.ORB_create(nfeatures=2000)
    features = [orb.detectAndCompute(cv2.cvtColor(im, cv2.COLOR_BGR2GRAY), None) for im in previews]
    candidates = [(i, i + 1) for i in range(len(previews) - 1)]
    if len(previews) > 2:
        candidates.append((0, len(previews) - 1))
    pairs = [{"frames": [i + 1, j + 1], **match_pair(features[i], features[j])} for i, j in candidates]
    stitcher = cv2.Stitcher_create(cv2.Stitcher_PANORAMA)
    stitcher.setRegistrationResol(0.25)
    stitcher.setSeamEstimationResol(0.10)
    stitcher.setCompositingResol(0.25)
    status, result = stitcher.stitch(previews)
    components = stitcher.component()
    used = [] if components is None else [int(i) + 1 for i in components]
    return {
        "preview_sizes": [[im.shape[1], im.shape[0]] for im in previews], "pairs": pairs,
        "stitch_status": status, "used_frames": used,
        "all_frames_stitched": status == cv2.Stitcher_OK and len(used) == len(previews),
        "panorama_size": [result.shape[1], result.shape[0]] if result is not None else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["hdr", "panorama"])
    parser.add_argument("files", type=Path, nargs="+", help="Camera originals in capture order")
    parser.add_argument("--temp-dir", required=True, type=Path, help="Parent of a new private result directory")
    parser.add_argument("--exiftool", default="exiftool", help="Executable name or path")
    args = parser.parse_args()
    minimum = 3 if args.mode == "hdr" else 2
    if len(args.files) < minimum:
        parser.error(f"{args.mode} needs at least {minimum} originals")
    tool = shutil.which(args.exiftool)
    if not tool:
        parser.error("ExifTool was not found. Supply --exiftool.")
    cv2.setNumThreads(1)
    cv2.setRNGSeed(333)
    try:
        paths = [p.resolve(strict=True) for p in args.files]
        before = [source_identity(path) for path in paths]
        if len({identity[:2] for identity in before}) != len(paths):
            raise ValueError("Each physical source file may appear only once.")
        metadata = json.loads(exif(tool, ["-j", "-n", "-Model", "-Orientation", "-ISO", "-FNumber",
                                          "-ExposureTime", *map(str, paths)]))
        if [entry.get("SourceFile") for entry in metadata] != list(map(str, paths)):
            raise ValueError("ExifTool did not return every input in the requested order.")
        previews = [frame_preview(tool, path, int(tags.get("Orientation", 1)))
                    for path, tags in zip(paths, metadata)]
        measurements = hdr(paths, metadata, previews) if args.mode == "hdr" else panorama(previews)
        source_digest = hashlib.sha256()
        for path in paths:
            with path.open("rb") as stream:
                source_digest.update(hashlib.file_digest(stream, "sha256").digest())
        if [source_identity(path) for path in paths] != before:
            raise ValueError("An original changed during measurement.")
        report = {
            "schema_version": 1, "mode": args.mode, "frame_count": len(paths),
            "ordered_source_sha256": source_digest.hexdigest(), "max_preview_edge_px": PREVIEW_EDGE,
            "versions": {"opencv": cv2.__version__, "rawpy": rawpy.__version__, "numpy": np.__version__,
                         "libraw": ".".join(map(str, rawpy.libraw_version)),
                         "exiftool": exif(tool, ["-ver"]).decode().strip()},
            "measurements": measurements,
        }
        args.temp_dir.mkdir(parents=True, exist_ok=True)
        run = Path(tempfile.mkdtemp(prefix=f"group-{args.mode}-", dir=args.temp_dir))
        with (run / "summary.json").open("x", encoding="utf-8") as output:
            json.dump(report, output, allow_nan=False, indent=2)
            output.write("\n")
        print(f"{run.name}/summary.json")
        return int(args.mode == "panorama" and not measurements["all_frames_stitched"])
    except (ValueError, OSError, RuntimeError, cv2.error, rawpy.LibRawError) as error:
        parser.exit(2, f"Probe failed: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
