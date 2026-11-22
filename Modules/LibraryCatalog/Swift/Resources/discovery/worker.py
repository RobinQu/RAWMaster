"""RawMaster offline local discovery worker. Protocol v1, one JSON line per operation."""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps
from tokenizers import Tokenizer


# Intel's normalized landmarks for the 128-pixel face-reidentification-retail-0095 input.
INTEL_TEMPLATE = np.array([
    [0.3155687500000000, 0.4615741071428571],
    [0.6826229166666667, 0.4615741071428571],
    [0.5002624999999999, 0.6405053571428571],
    [0.3494718750000000, 0.8246919642857142],
    [0.6534364583333333, 0.8246919642857142],
]) * 128


class InvalidFaceLandmarks(ValueError):
    pass


def align_five_points(image, source, target, size):
    center = source.mean(axis=0)
    to_center = target.mean(axis=0)
    relative = source - center
    variance = np.sum(relative * relative)
    if not np.isfinite(variance) or variance < 1.0:
        raise InvalidFaceLandmarks("invalid face landmarks")
    u, values, vt = np.linalg.svd(relative.T @ (target - to_center))
    if values[1] <= values[0] * 1e-6:
        raise InvalidFaceLandmarks("degenerate face landmarks")
    signs = np.array([1.0, np.linalg.det(vt.T @ u.T)])
    matrix = ((vt.T * signs) @ u.T) * (values.dot(signs) / variance)
    transform = np.column_stack((matrix, to_center - matrix @ center))
    return cv2.warpAffine(image, transform, (size, size), flags=cv2.INTER_LINEAR,
                          borderMode=cv2.BORDER_CONSTANT, borderValue=0)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def unit(raw):
    vector = np.asarray(raw, dtype=np.float32).reshape(-1)
    length = np.linalg.norm(vector)
    if not np.isfinite(length) or length < 1e-8:
        raise ValueError("invalid model result")
    return vector / length


class Runtime:
    def __init__(self, models):
        self.models = Path(models).resolve(strict=True)
        self.manifest = json.loads(Path(__file__).with_name("models.json").read_text())
        self.verified = set()
        self.sessions = {}
        self.tokenizer = None
        self.detector = None
        self.face_encoder = None
        cv2.setNumThreads(2)

    def artifact(self, name):
        path = self.models / name
        if name not in self.verified:
            if digest(path) != self.manifest["sha256"][name]:
                raise ValueError("invalid local model digest for " + name)
            self.verified.add(name)
        return str(path)

    def session(self, tower):
        if tower not in self.sessions:
            options = ort.SessionOptions()
            options.intra_op_num_threads = 2
            options.inter_op_num_threads = 1
            self.sessions[tower] = ort.InferenceSession(
                self.artifact(tower + "-f16w.onnx"),
                options,
                providers=["CPUExecutionProvider"],
            )
        return self.sessions[tower]

    def text_input(self, query):
        if not isinstance(query, str) or not query.strip() or len(query) > 4096:
            raise ValueError("invalid visual search text")
        if self.tokenizer is None:
            self.tokenizer = Tokenizer.from_file(self.artifact("tokenizer.json"))
            self.tokenizer.enable_truncation(max_length=64)
            self.tokenizer.enable_padding(
                length=64, pad_id=self.tokenizer.token_to_id("<pad>"), pad_token="<pad>"
            )
        return np.array([self.tokenizer.encode(query).ids], dtype=np.int64)

    def pixels(self, image):
        config = json.loads(Path(self.artifact("preprocessor_config.json")).read_text())
        size = config["size"]
        resized = image.resize(
            (size["width"], size["height"]), Image.Resampling(config["resample"])
        )
        pix = np.asarray(resized, np.float32) * np.float32(config["rescale_factor"])
        pix = (pix - np.array(config["image_mean"], np.float32)) / np.array(
            config["image_std"], np.float32
        )
        return np.ascontiguousarray(pix.transpose(2, 0, 1)[None])

    def face_regions(self, bgr):
        if self.detector is None:
            self.detector = cv2.FaceDetectorYN.create(
                self.artifact("yunet.onnx"), "", (320, 320), 0.9, 0.3, 5000
            )
        h, w = bgr.shape[:2]
        scale = min(1.0, 1024 / max(w, h))
        dw, dh = max(1, round(w * scale)), max(1, round(h * scale))
        small = cv2.resize(bgr, (dw, dh), interpolation=cv2.INTER_AREA)
        self.detector.setInputSize((dw, dh))
        _, detections = self.detector.detect(small)
        regions = []
        for face in sorted([] if detections is None else detections, key=lambda f: (float(f[0]), float(f[1]))):
            points = face.copy()
            points[:14:2] *= w / dw
            points[1:14:2] *= h / dh
            x, y, bw, bh = [float(n) for n in points[:4]]
            left, top, right, bottom = np.clip([x / w, y / h, (x + bw) / w, (y + bh) / h], 0.0, 1.0)
            if left >= right or top >= bottom:
                continue
            landmarks = np.clip(points[4:14].reshape(5, 2) / [w, h], 0.0, 1.0)
            if not np.isfinite(landmarks).all():
                continue
            regions.append((
                {"box": [left, top, right - left, bottom - top],
                 "landmarks": landmarks.tolist(), "confidence": float(face[14])},
                landmarks * [w, h],
            ))
        return regions

    def face_embedding(self, bgr, landmarks):
        face = self.manifest["faceEncoder"]
        chip = align_five_points(bgr, landmarks, INTEL_TEMPLATE, face["size"])
        pixels = np.ascontiguousarray(chip.transpose(2, 0, 1)[None], dtype=np.float32)
        if self.face_encoder is None:
            options = ort.SessionOptions()
            options.intra_op_num_threads = options.inter_op_num_threads = 1
            self.face_encoder = ort.InferenceSession(
                self.artifact(face["file"]), options, providers=["CPUExecutionProvider"]
            )
        (input_info,) = self.face_encoder.get_inputs()
        (result,) = self.face_encoder.run(None, {input_info.name: pixels})
        v = unit(result)
        if len(v) != face["dimensions"]:
            raise ValueError("invalid face embedding dimension")
        return v

    def faces(self, image):
        bgr = cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR)
        results = []
        for face, landmarks in self.face_regions(bgr):
            try:
                feature = self.face_embedding(bgr, landmarks)
            except InvalidFaceLandmarks:
                continue
            results.append({**face, "vector": feature.tolist()})
        return results

    def run(self, req):
        op = req.get("op")
        if req.get("version") != 1:
            raise ValueError("unsupported local worker descriptor")
        if op == "text":
            vec = self.session("text").run(
                ["embedding"], {"input_ids": self.text_input(req.get("text"))}
            )[0]
            return {"vector": unit(vec).tolist(), "model": self.manifest["sceneModel"]}
        if op not in ("scene", "faces"):
            raise ValueError("unknown worker operation")
        path = Path(req["proxy"])
        if (
            not path.is_absolute()
            or not path.is_file()
            or path.stat().st_size > 64 * 1024 * 1024
        ):
            raise ValueError("invalid local prepared proxy")
        sha = digest(path)
        with Image.open(path) as src:
            if src.width * src.height > 40_000_000:
                raise ValueError("input must be a prepared proxy")
            image = ImageOps.exif_transpose(src).convert("RGB")
        if op == "faces":
            return {
                "faces": self.faces(image),
                "model": self.manifest["faceModel"],
                "proxySHA256": sha,
            }
        vec = self.session("vision").run(
            ["embedding"], {"pixel_values": self.pixels(image)}
        )[0]
        return {
            "vector": unit(vec).tolist(),
            "model": self.manifest["sceneModel"],
            "proxySHA256": sha,
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True, type=Path)
    runtime = Runtime(parser.parse_args().models)
    for line in sys.stdin.buffer:
        try:
            if len(line) > 64_000:
                raise ValueError("oversized input descriptor")
            answer = {"ok": True, "result": runtime.run(json.loads(line))}
        except (OSError, ValueError, RuntimeError, KeyError, cv2.error) as err:
            answer = {"ok": False, "error": str(err)}
        print(json.dumps(answer, separators=(",", ":"), allow_nan=False), flush=True)


if __name__ == "__main__":
    main()
