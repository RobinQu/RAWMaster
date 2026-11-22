#!/usr/bin/env python3
"""Compare official SigLIP2 inference and two exported towers on local labeled proxies."""

import argparse
import importlib.util
import json
import time
from pathlib import Path
import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps
import torch
from transformers import SiglipModel

RESOURCE = Path(__file__).resolve().parents[1] / "Swift/Resources/discovery/worker.py"
spec = importlib.util.spec_from_file_location("rawmaster_discovery_worker", RESOURCE)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source", type=Path, required=True, help="official fixed Google checkpoint"
    )
    ap.add_argument(
        "--models",
        type=Path,
        required=True,
        help="output of convert-discovery-model.py",
    )
    ap.add_argument(
        "--cases",
        type=Path,
        required=True,
        help="anonymous samples, source events, proxy checksums and frozen relevance judgments",
    )
    ap.add_argument(
        "--proxies",
        type=Path,
        required=True,
        help="one oriented local <sample-id>.jpg per item",
    )
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    cases = json.loads(args.cases.read_text())
    expected = json.loads(RESOURCE.with_name("models.json").read_text())
    if worker.digest(args.source / "model.safetensors") != expected["sourceSHA256"]:
        raise ValueError("source weight digest mismatch")
    runtime = worker.Runtime(args.models)
    torch.set_num_threads(2)
    ref = SiglipModel.from_pretrained(
        args.source, local_files_only=True, attn_implementation="eager"
    ).eval()
    sessions = {}
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    for tower in ["vision", "text"]:
        for precision in ["fp32", "q8"]:
            sessions[(tower, precision)] = ort.InferenceSession(
                str(args.models / f"{tower}-{precision}.onnx"),
                options,
                providers=["CPUExecutionProvider"],
            )
    formats = ["official", "fp32", "q8", "f16w"]
    times = {tower: {k: [] for k in formats} for tower in ["vision", "text"]}

    def encode(tower, tensor):
        arg = "pixel_values" if tower == "vision" else "input_ids"
        rep = {}
        for label in formats:
            start = time.perf_counter()
            if label == "official":
                with torch.inference_mode():
                    raw = (ref.vision_model if tower == "vision" else ref.text_model)(
                        **{arg: torch.from_numpy(tensor)}
                    ).pooler_output.numpy()
            else:
                s = (
                    runtime.session(tower)
                    if label == "f16w"
                    else sessions[(tower, label)]
                )
                raw = s.run(["embedding"], {arg: tensor})[0]
            rep[label] = worker.unit(raw)
            times[tower][label].append((time.perf_counter() - start) * 1000)
        return rep

    images = {k: [] for k in formats}
    ids = []
    for item in cases["samples"]:
        i = item["id"]
        if not i.isalnum() or i in ids:
            raise ValueError("invalid or duplicate sample ID")
        p = args.proxies / (i + ".jpg")
        if worker.digest(p) != item["proxySHA256"]:
            raise ValueError("wrong proxy for " + i)
        with Image.open(p) as im:
            features = encode(
                "vision", runtime.pixels(ImageOps.exif_transpose(im).convert("RGB"))
            )
        for label, feat in features.items():
            images[label].append(feat)
        ids.append(i)
    images = {k: np.stack(v) for k, v in images.items()}
    queries = {k: [] for k in formats}
    results = []
    for q in cases["queries"]:
        valid = set(q["relevant"])
        if valid - set(ids):
            raise ValueError("unrecognized relevance ID")
        vectors = encode("text", runtime.text_input(q["text"]))
        ranks = {}
        for k, vec in vectors.items():
            queries[k].append(vec)
            scores = np.einsum("ij,j->i", images[k], vec, optimize=False)
            if not np.isfinite(scores).all():
                raise ValueError("invalid cosine result")
            order = np.argsort(-scores, kind="stable").tolist()
            ranked = [ids[ix] for ix in order]
            ranks[k] = {
                "top": ranked[0],
                "score": float(scores[order[0]]),
                "relevantRanks": sorted(ranked.index(i) + 1 for i in valid),
            }
        results.append(
            {"text": q["text"], "relevant": sorted(valid), "rankings": ranks}
        )
    queries = {k: np.stack(v) for k, v in queries.items()}

    def error(matrix):
        return {
            k: {
                "minCosine": float(
                    np.einsum(
                        "ij,ij->i", matrix["official"], matrix[k], optimize=False
                    ).min()
                ),
                "maxAbs": float(abs(matrix["official"] - matrix[k]).max()),
            }
            for k in formats[1:]
        }

    metrics = {
        "schema": 1,
        "machine": "local CPU, two intra-op threads",
        "reference": expected["source"],
        "shipModel": expected["sceneModel"],
        "images": len(ids),
        "events": len({s["event"] for s in cases["samples"]}),
        "imageError": error(images),
        "textError": error(queries),
        "queries": results,
        "timingsMs": {
            t: {
                k: {
                    "first": v[0],
                    "p50": float(np.median(v)),
                    "p95": float(np.percentile(v, 95)),
                }
                for k, v in d.items()
            }
            for t, d in times.items()
        },
    }
    args.output.write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
