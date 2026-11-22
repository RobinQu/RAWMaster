#!/usr/bin/env python3
"""Freeze real, manually confirmed faces for an offline recognition comparison."""

import argparse
import collections
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys

import cv2
import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Swift/Resources/discovery"))
from worker import Runtime, align_five_points, digest

ARC_FACE_TEMPLATE = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]])


def confirmed_regions(catalog):
    """The caller supplies an already coherent Lightroom snapshot."""
    with sqlite3.connect(catalog.resolve().as_uri() + "?mode=ro&immutable=1", uri=True) as db:
        db.row_factory = sqlite3.Row
        sql = """
        SELECT k.tag, i.rootFile, i.captureTime, fi.baseName, fi.extension, fo.pathFromRoot, root.absolutePath,
               f.imageOrientation, f.tl_x, f.tl_y, f.tr_x, f.tr_y, f.bl_x, f.bl_y, f.br_x, f.br_y,
               e.cameraModelRef, e.cameraSNRef
        FROM AgLibraryKeywordFace k JOIN AgLibraryFace f ON f.id_local=k.face
        JOIN Adobe_images i ON i.id_local=f.image JOIN AgLibraryFile fi ON fi.id_local=i.rootFile
        JOIN AgLibraryFolder fo ON fo.id_local=fi.folder JOIN AgLibraryRootFolder root ON root.id_local=fo.rootFolder
        LEFT JOIN AgHarvestedExifMetadata e ON e.image=i.id_local
        WHERE k.userPick=1 AND coalesce(k.userReject,0)=0 AND coalesce(f.ignored,0)=0
        ORDER BY i.rootFile,f.id_local
        """
        photos = collections.defaultdict(list)
        for row in db.execute(sql):
            photo = dict(row)
            photo["source"] = (
                Path(photo["absolutePath"]) / photo["pathFromRoot"]
                / (photo["baseName"] + "." + photo["extension"])
            )
            photos[photo["rootFile"]].append(photo)
    return photos


def normalized_time(value):
    return "".join(x for x in (value or "")[:19] if x.isdigit())


def prepare_photo(item, folder, max_edge):
    _, labels = item
    src = labels[0]["source"]
    if not src.is_file():
        return None, "unavailable"
    before = src.stat()
    fingerprint = hashlib.sha256(
        f"{src}:{before.st_dev}:{before.st_ino}:{before.st_mtime_ns}:{before.st_size}".encode()
    ).hexdigest()
    output = folder / (fingerprint + ".jpg")
    if not output.exists():
        proc = subprocess.run(
            ["sips", "-s", "format", "jpeg", "-Z", str(max_edge), str(src), "--out", str(output)],
            capture_output=True,
        )
        if proc.returncode or not output.is_file():
            return None, "decode"
    after = src.stat()
    if (after.st_ino, after.st_size, after.st_mtime_ns) != (
        before.st_ino, before.st_size, before.st_mtime_ns
    ):
        return None, "sourceChanged"
    with Image.open(output) as image:
        exif = image.getexif().get_ifd(34665)
        if not normalized_time(exif.get(36867)) or normalized_time(exif.get(36867)) != normalized_time(labels[0]["captureTime"]):
            return None, "captureTimeMismatch"
    return output, None


def region(row, convention):
    corners = np.array([[row[p + "_x"], row[p + "_y"]] for p in ("tl", "tr", "bl", "br")])
    x, y = corners[:, 0], corners[:, 1]
    if convention & 4:
        x, y = y, x
    if convention & 2:
        x = 1 - x
    if convention & 1:
        y = 1 - y
    return [x.min(), y.min(), x.max() - x.min(), y.max() - y.min()]


def iou(a, b):
    overlap = max(min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]), 0)
    overlap *= max(min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]), 0)
    return overlap / max(a[2] * a[3] + b[2] * b[3] - overlap, 1e-12)


def crop_context(bgr, box):
    height, width = bgr.shape[:2]
    x, y, bw, bh = np.array(box) * [width, height, width, height]
    side = max(bw, bh) * 1.35
    scale = 224 / side
    transform = np.float32([
        [scale, 0, 112 - scale * (x + bw / 2)],
        [0, scale, 112 - scale * (y + bh / 2)]
    ])
    return cv2.warpAffine(bgr, transform, (224, 224), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)


def prepare(args):
    photos = confirmed_regions(args.catalog)
    args.output.mkdir(parents=True, mode=0o700)
    proxy_dir = args.output / "proxies"
    proxy_dir.mkdir(mode=0o700)
    crop_dir = args.output / "crops"
    crop_dir.mkdir(mode=0o700)
    runtime = Runtime(args.models)
    aligner = cv2.FaceRecognizerSF.create(str(args.sface_aligner), "") if args.sface_aligner else None
    photo_names = {key: f"P{n:04}" for n, key in enumerate(photos, 1)}
    labels = [r for rows in photos.values() for r in rows]
    people = {key: f"I{n:03}" for n, key in enumerate(sorted({r["tag"] for r in labels}), 1)}
    days = sorted({r["captureTime"][:10] for r in labels})
    # Only orientation geometry is fit here. No recognition scoring contributes to the transform.
    orientations = sorted({r["imageOrientation"] for r in labels})
    calibration = []
    for day in days:
        calibration.append(day)
        counts = collections.Counter(r["imageOrientation"] for r in labels if r["captureTime"][:10] in calibration)
        if len(calibration) >= 3 and all(counts[o] >= 2 for o in orientations):
            break
    shots = {}
    errors = collections.Counter()
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = pool.map(lambda item: prepare_photo(item, args.reuse_proxies or proxy_dir, args.max_edge), photos.items())
        for key, (path, error) in zip(photos, results, strict=True):
            if error:
                errors[error] += 1
                continue
            with Image.open(path) as image:
                bgr = cv2.cvtColor(np.asarray(ImageOps.exif_transpose(image).convert("RGB")), cv2.COLOR_RGB2BGR)
            if hasattr(runtime, "face_regions"):
                faces = [item[0] for item in runtime.face_regions(bgr)]
            else:
                faces = [
                    {k: v for k, v in f.items() if k != "vector"}
                    for f in runtime.faces(Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))
                ]
            shots[key] = (path, faces)

    def score(label, convention):
        return [iou(region(label, convention), f["box"]) for f in shots.get(label["rootFile"], (None, []))[1]]

    mapping = {}
    for o in orientations:
        matching = [r for r in labels if r["imageOrientation"] == o and r["captureTime"][:10] in calibration]
        scores = [sum(max(score(r, n), default=0) for r in matching) for n in range(8)]
        mapping[o] = int(np.argmax(scores))
    manifest = []
    unseen = []
    serials = {}
    models = {}
    if args.exiftool:
        paths = [str(rows[0]["source"]) for key, rows in photos.items() if key in shots]
        result = subprocess.run(
            [str(args.exiftool), "-config", "", "-j", "-n", "-G1", "-SerialNumber",
             "-InternalSerialNumber", "-CameraSerialNumber", "-BodySerialNumber", "-Make", "-Model", *paths],
            capture_output=True, text=True, check=True,
        )
        for record in json.loads(result.stdout):
            priority = ("Sony:InternalSerialNumber", "EXIF:BodySerialNumber", "ExifIFD:SerialNumber",
                        "ExifIFD:BodySerialNumber", "Canon:SerialNumber", "Nikon:SerialNumber", "Leica:SerialNumber")
            serial = next((record[key] for key in priority if key in record), None)
            if serial is None:
                serial = next((v for k, v in record.items() if k.endswith(":SerialNumber")), None)
            make = str(record.get("IFD0:Make", "")).strip().casefold()
            model = str(record.get("IFD0:Model", "")).strip().casefold()
            if model:
                models[record["SourceFile"]] = (make, model)
            if model and serial is not None and str(serial).strip() not in ("", "0", "0000000", "Unknown"):
                serials[record["SourceFile"]] = (make, model, str(serial).strip())

    def body_key(row):
        raw = serials.get(str(row["source"]))
        if raw is not None:
            return raw
        if row["cameraSNRef"] is not None:
            return (row["cameraModelRef"], row["cameraSNRef"])
        return None

    def camera_key(row):
        return models.get(str(row["source"])) or row["cameraModelRef"]

    bodies = {}
    cameras = {}
    for rows in photos.values():
        serial = body_key(rows[0])
        if serial is not None:
            bodies.setdefault(serial, f"B{len(bodies) + 1:03}")
        model = camera_key(rows[0])
        if model is not None:
            cameras.setdefault(model, f"C{len(cameras) + 1:03}")

    for key, rows in photos.items():
        matches = []
        for row in rows:
            overlaps = [ix for ix, overlap in enumerate(score(row, mapping[row["imageOrientation"]])) if overlap >= 0.35]
            matches.append(overlaps[0] if len(overlaps) == 1 else None)
        for n, (row, ix) in enumerate(zip(rows, matches, strict=True), 1):
            face_id = f"{photo_names[key]}-{n:02}"
            serial = body_key(row)
            meta = {"faceID": face_id, "imageID": photo_names[key], "personID": people[row["tag"]],
                    "day": row["captureTime"][:10], "camera": cameras.get(camera_key(row)),
                    "body": bodies.get(serial), "truthBox": region(row, mapping[row["imageOrientation"]])}
            if ix is None or matches.count(ix) != 1:
                unseen.append(meta)
                continue
            path, found = shots[key]
            face = found[ix]
            with Image.open(path) as image:
                bgr = cv2.cvtColor(np.asarray(ImageOps.exif_transpose(image).convert("RGB")), cv2.COLOR_RGB2BGR)
            h, w = bgr.shape[:2]
            landmarks = (np.array(face["landmarks"]) * [w, h]).astype(np.float32)
            detection = np.array([*(np.array(face["box"]) * [w,h,w,h]), *landmarks.ravel(), face["confidence"]], dtype=np.float32)
            align_path = crop_dir / (face_id + "-112.png")
            context_path = crop_dir / (face_id + "-context.png")
            aligned = (aligner.alignCrop(bgr, detection) if aligner is not None
                       else align_five_points(bgr, landmarks, ARC_FACE_TEMPLATE, 112))
            if not cv2.imwrite(str(align_path), aligned):
                raise OSError("unable to write aligned crop")
            if not cv2.imwrite(str(context_path), crop_context(bgr, face["box"])):
                raise OSError("unable to write context crop")
            manifest.append({
                **meta, "alignedPath": str(align_path.resolve()), "contextPath": str(context_path.resolve()),
                "proxyPath": str(path.resolve()), "proxySHA256": digest(path), "box": face["box"],
                "landmarks": face["landmarks"], "detectionScore": face["confidence"],
                "faceWidthPixels": face["box"][2] * w,
                "alignedSHA256": digest(align_path), "contextSHA256": digest(context_path),
            })
    metadata = {"confirmedFaces": len(labels), "originals": len(photos), "usableProxies": len(shots),
                "detectedAndMapped": len(manifest), "unmapped": len(unseen), "errors": errors,
                "geometryCalibrationDays": len(calibration), "orientationMap": mapping,
                "cropPolicy": "sRGB 1024 JPEG; YuNet; one-to-one IoU≥0.35; 112 five-point align; centered 224 context",
                "detector": runtime.manifest["sha256"]["yunet.onnx"]}
    metadata["cameraModelsFromEXIF"] = len(set(models.values()))
    metadata["originalsWithSerialFromEXIF"] = len(serials)
    photo_rows = []
    for key, (path, _) in shots.items():
        row = photos[key][0]
        photo_rows.append({"imageID": photo_names[key], "proxyPath": str(path.resolve()),
                           "originalPath": str(row["source"]), "body": bodies.get(body_key(row)),
                           "day": row["captureTime"][:10]})
    report = {"protocol": 1, "metadata": metadata, "faces": manifest, "unmapped": unseen, "photos": photo_rows}
    (args.output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(metadata))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, required=True)
    p.add_argument("--models", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--exiftool", type=Path, help="Read camera serials privately, recording only anonymous body IDs")
    p.add_argument("--max-edge", type=int, default=1024)
    p.add_argument("--sface-aligner", type=Path, help="OpenCV SFace weights for the exact historical ArcFace-aligned comparison crop")
    p.add_argument("--reuse-proxies", type=Path, help="Reuse the private, content-matched JPEG proxies at the same size")
    prepare(p.parse_args())


if __name__ == "__main__":
    main()
