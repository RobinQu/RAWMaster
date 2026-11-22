"""Private comparison on the frozen, anonymized RAWMaster landmark fixture."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import time

import numpy as np

WEIGHTS = {
    "buffalo_l": ("w600k_r50.onnx", "4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43"),
    "antelopev2": ("glintr100.onnx", "4ab1d6435d639628a6f3e5008dd4f929edf4c4124b1a7169e1048f9fef534cdf"),
    "farl_ep64": ("FaRL-ep64.pth", "ab3534c4c2377a853926b99456fc4a10140ea092213b9c8d32458e06ec0961b7"),
}


def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def arcface(path, threads):
    import cv2
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.log_severity_level = 3
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.intra_op_num_threads = threads
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    output_name = session.get_outputs()[0].name

    def prepare(raw):
        bgr = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        if bgr is None or bgr.shape != (112, 112, 3):
            raise ValueError("Expected the frozen 112x112 five-point PNG")
        return cv2.dnn.blobFromImage(bgr, 1 / 127.5, (112, 112), (127.5, 127.5, 127.5), swapRB=True)[0]

    def forward(rows):
        return session.run([output_name], {input_name: np.stack(rows)})[0]

    return prepare, forward, {
        "runtime": "onnxruntime", "version": ort.__version__, "provider": session.get_providers(),
        "opencv": cv2.__version__, "inputTensor": input_name, "outputTensor": output_name,
        "decode": "OpenCV BGR PNG -> swapRB -> RGB NCHW float32",
        "inputNormalization": "(uint8 - 127.5) / 127.5",
        "resolution": [112, 112], "threads": threads, "interOpThreads": 1,
    }


def farl(path, threads, clip_source):
    from PIL import Image, __version__ as pillow_version
    import torch

    torch.set_num_threads(threads)
    torch.set_num_interop_threads(1)
    source = clip_source
    spec = importlib.util.spec_from_file_location("farl_official_clip_model", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    visual = module.VisionTransformer(input_resolution=224, patch_size=16, width=768, layers=12, heads=12, output_dim=512)
    state = torch.load(path, weights_only=True, map_location="cpu")["state_dict"]
    # The checkpoint contains a text encoder and masked-image pretraining heads.
    # Select every parameter used by the official CLIP visual forward, including its projection.
    required = visual.state_dict()
    matched = {key: state["visual." + key] for key in required}
    visual.load_state_dict(matched, strict=True)
    extras = sorted(key for key in state if key.startswith("visual.") and key[7:] not in required)
    del state, matched
    visual.float().eval()
    mean = [0.48145466, 0.4578275, 0.40821073]
    std = [0.26862954, 0.26130258, 0.27577711]
    mean_tensor = torch.tensor(mean, dtype=torch.float32)[:, None, None]
    std_tensor = torch.tensor(std, dtype=torch.float32)[:, None, None]

    def prepare(raw):
        with Image.open(io.BytesIO(raw)) as image:
            if image.width != image.height:
                raise ValueError("FaRL comparison requires a square frozen face crop")
            rgb = image.convert("RGB").resize((224, 224), Image.Resampling.BICUBIC)
            pixels = torch.from_numpy(np.array(rgb)).permute(2, 0, 1).float().div_(255)
            return pixels.sub_(mean_tensor).div_(std_tensor)

    def forward(rows):
        with torch.inference_mode():
            return visual(torch.stack(rows)).cpu().numpy()

    return prepare, forward, {
        "runtime": "torch", "version": torch.__version__, "provider": ["cpu"],
        "pillow": pillow_version,
        "architecture": "OpenAI CLIP ViT-B/16 visual CLS, final LayerNorm, learned 768x512 projection",
        "strictVisualParameterCount": len(required), "extraPretrainingKeys": extras,
        "clipVisionSourceSHA256": file_digest(source),
        "decode": "Pillow RGB, bicubic resize of square crop to 224 pixels, float32 tensor",
        "inputNormalization": {"mean": mean, "std": std, "inputRange": [0, 1]},
        "resolution": [224, 224], "threads": threads, "interOpThreads": 1,
    }


def normalized(matrix, count):
    matrix = np.asarray(matrix, dtype=np.float32)
    if matrix.shape != (count, 512) or not np.isfinite(matrix).all():
        raise ValueError("Unexpected encoder output")
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    if np.any(norms < 1e-10):
        raise ValueError("Empty embedding")
    return matrix / norms


def measured(function):
    tick = time.perf_counter_ns()
    value = function()
    return value, (time.perf_counter_ns() - tick) / 1e6


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=WEIGHTS, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--weights-dir", type=Path, required=True)
    parser.add_argument("--clip-source", type=Path, help="Pinned research CLIP model.py for the FaRL encoder")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--crop", choices=("aligned", "context"), default="aligned")
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--batch", type=int, default=4)
    args = parser.parse_args()
    if args.model != "farl_ep64" and args.crop != "aligned":
        parser.error("ArcFace takes the frozen canonical 112-pixel crop")
    if min(args.threads, args.batch) < 1:
        parser.error("threads and batch must be positive")
    os.umask(0o077)
    manifest = json.loads(args.manifest.read_bytes())
    if manifest["protocol"] != 1 or not manifest["faces"]:
        raise ValueError("Missing or unsupported frozen fixture")
    weight_name, expected = WEIGHTS[args.model]
    weight = args.weights_dir / weight_name
    sha, verify_ms = measured(lambda: file_digest(weight))
    if sha != expected:
        raise ValueError("Checkpoint digest mismatch")
    if args.model == "farl_ep64" and not args.clip_source:
        parser.error("FaRL requires --clip-source")
    def initialize():
        if args.model == "farl_ep64":
            return farl(weight, args.threads, args.clip_source)
        return arcface(weight, args.threads)
    (prepare, forward, settings), load_ms = measured(initialize)
    ids, images, prepare_ms = [], [], []
    input_evidence = hashlib.sha256()
    for row in manifest["faces"]:
        key = row["faceID"]
        raw = Path(row[args.crop + "Path"]).read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if digest != row[args.crop + "SHA256"] or key in ids:
            raise ValueError("Changed crop or duplicated anonymous observation")
        input_evidence.update((key + "/" + digest + "\n").encode())
        item, elapsed = measured(lambda: prepare(raw))
        ids.append(key)
        images.append(item)
        prepare_ms.append(elapsed)
    _, first_ms = measured(lambda: forward(images[:1]))
    for _ in range(3):
        forward(images[:1])
    vectors = []
    single_ms = []
    for row in images:
        out, elapsed = measured(lambda: forward([row]))
        vectors.append(normalized(out, 1)[0])
        single_ms.append(elapsed)
    vectors = np.stack(vectors)
    batch_ms = []
    batched = []
    forward(images[:min(args.batch, len(images))])
    for offset in range(0, len(images), args.batch):
        group = images[offset:offset + args.batch]
        out, elapsed = measured(lambda: forward(group))
        batched.append(normalized(out, len(group)))
        batch_ms.append(elapsed)
    batched = np.concatenate(batched)
    cosine_delta = np.abs(1 - np.einsum("ij,ij->i", batched, vectors))
    if cosine_delta.max() > 1e-4:
        raise ValueError("Single and batched embedding passes disagree")
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    report = {
        "model": args.model + "_" + args.crop, "weightsSHA256": sha,
        "weightBytes": weight.stat().st_size, "dimensions": 512, "count": len(ids),
        "preprocessing": {**settings, "crop": args.crop, "flip": False,
                          "output": "L2 normalized float32; cosine = dot product"},
        "latencyMs": {
            "p50": float(np.median(single_ms)), "p95": float(np.percentile(single_ms, 95)),
            "coldStart": load_ms + first_ms, "loadIncludingRuntimeImport": load_ms,
            "firstForward": first_ms, "weightHashVerification": verify_ms,
            "prepareP50": float(np.median(prepare_ms)), "prepareP95": float(np.percentile(prepare_ms, 95)),
            "rssPeakBytes": int(rss if platform.system() == "Darwin" else rss * 1024),
            "measuredSinglePasses": len(single_ms), "warmupPasses": 3,
            "timedRegion": "Synchronous CPU forward, preprocessed host input; excludes image I/O and vector normalization.",
        },
        "batch": {"size": args.batch, "batches": len(batch_ms), "p50Ms": float(np.median(batch_ms)),
                  "p95Ms": float(np.percentile(batch_ms,95)), "facesPerSecond": len(ids) * 1000 / sum(batch_ms),
                  "maxAbsCosineDeltaVsSingles": float(cosine_delta.max())},
        "fixtureProtocol": manifest["protocol"], "orderedAnonymousInputSHA256": input_evidence.hexdigest(),
        "runtimeHost": {"architecture": platform.machine(), "macOS": platform.mac_ver()[0],
                        "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()},
        "vectors": {key: value.tolist() for key, value in zip(ids, vectors)},
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    temp = args.out.with_suffix(".partial")
    temp.write_text(json.dumps(report, allow_nan=False, separators=(",", ":")))
    os.replace(temp, args.out)
    print(json.dumps({key: report[key] for key in ("model","count","dimensions","latencyMs","batch")}, indent=2))


if __name__ == "__main__":
    main()
