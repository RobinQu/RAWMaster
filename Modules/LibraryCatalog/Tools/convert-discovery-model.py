#!/usr/bin/env python3
"""Build the exact CPU model used by the local discovery runtime, entirely offline."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil

import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto
import onnxruntime as ort
from onnxruntime.quantization import QuantType, quantize_dynamic
import torch
from transformers import SiglipModel

REVISION = "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"
WEIGHT_SHA = "612923381c76ec5a9bed335d1c48827e3f2e506ac31b044b63b2031fadee6a0b"


def sha(p):
    with p.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def compact_weights(source, target):
    # Preserve FP32 operators. Storing initializers as IEEE half precision has
    # a different numerical contract from quantizing intermediate activations.
    graph = onnx.load(str(source))
    casts = []
    for tensor in graph.graph.initializer:
        if tensor.data_type != TensorProto.FLOAT or np.prod(tensor.dims) < 64:
            continue
        original = tensor.name
        replacement = original + ".rawmaster_f16w"
        half = numpy_helper.to_array(tensor).astype(np.float16)
        tensor.CopyFrom(numpy_helper.from_array(half, replacement))
        casts.append(
            helper.make_node("Cast", [replacement], [original], to=TensorProto.FLOAT)
        )
    previous = list(graph.graph.node)
    del graph.graph.node[:]
    graph.graph.node.extend([*casts, *previous])
    onnx.checker.check_model(graph)
    onnx.save(graph, str(target))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    src, out = args.source, args.output
    if sha(src / "model.safetensors") != WEIGHT_SHA:
        raise ValueError("Unexpected Google SigLIP2 source weights")
    out.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(2)
    model = SiglipModel.from_pretrained(
        src, local_files_only=True, attn_implementation="eager"
    ).eval()

    class Vision(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.tower = model.vision_model

        def forward(self, pixel_values):
            return self.tower(pixel_values=pixel_values).pooler_output

    class Text(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.tower = model.text_model

        def forward(self, input_ids):
            return self.tower(input_ids=input_ids).pooler_output

    ops = {
        "op_types_to_quantize": ["MatMul", "Gemm", "Gather"],
        "weight_type": QuantType.QInt8,
    }
    for key, arg, tower, tensor in [
        ("vision", "pixel_values", Vision(), torch.zeros((1, 3, 224, 224))),
        ("text", "input_ids", Text(), torch.ones((1, 64), dtype=torch.int64)),
    ]:
        fp32, q8 = out / f"{key}-fp32.onnx", out / f"{key}-q8.onnx"
        if not fp32.exists():
            with torch.inference_mode():
                torch.onnx.export(
                    tower.eval(),
                    (tensor,),
                    fp32,
                    opset_version=17,
                    dynamo=False,
                    input_names=[arg],
                    output_names=["embedding"],
                    external_data=False,
                )
        if not q8.exists():
            quantize_dynamic(str(fp32), str(q8), **ops)
        compact_weights(fp32, out / f"{key}-f16w.onnx")
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        vector = ort.InferenceSession(
            str(q8), options, providers=["CPUExecutionProvider"]
        ).run(["embedding"], {arg: tensor.numpy()})[0]
        if vector.shape != (1, 768) or not np.isfinite(vector).all():
            raise ValueError("Unexpected converted model output")
        print(key, sha(q8), q8.stat().st_size, flush=True)
    for name in ["tokenizer.json", "preprocessor_config.json"]:
        shutil.copyfile(src / name, out / name)
    files = [
        "vision-f16w.onnx",
        "text-f16w.onnx",
        "vision-q8.onnx",
        "text-q8.onnx",
        "tokenizer.json",
        "preprocessor_config.json",
    ]
    report = {
        "source": REVISION,
        "sourceSHA256": WEIGHT_SHA,
        "sha256": {n: sha(out / n) for n in files},
    }
    (out / "conversion.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
