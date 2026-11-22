#!/usr/bin/env python3
"""Convert the author's pinned RealPLKSR still-image denoising checkpoint to a fixed-tile Core ML program."""
import argparse
import hashlib
import json
from pathlib import Path


REVISION = "829b63fdbf8b1271595893bdaee6818bdada46bb"
SHA256 = "0a3e22bdcb70dd790fce66f45df8d07e774e269b17c92a2835162b150d4a365c"


def tensors(path):
    import numpy as np

    payload = path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != SHA256:
        raise ValueError("Unexpected safetensors SHA-256")
    length = int.from_bytes(payload[:8], "little")
    index = json.loads(payload[8:8 + length])
    storage = memoryview(payload)[8 + length:]
    result = {}
    for name, descriptor in index.items():
        if descriptor["dtype"] != "F32":
            raise ValueError(f"Unexpected tensor type for {name}")
        start, end = descriptor["data_offsets"]
        result[name] = np.frombuffer(storage[start:end], dtype="<f4").reshape(descriptor["shape"])
    return result


def convert(weights, side, destination):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    # This checkpoint has 28 residual blocks. Each uses 64 channels split into four
    # normalization groups, as independently checked against the author's ONNX graph.
    def convolution(x, prefix):
        weight = weights.pop(prefix + ".weight")
        return mb.conv(x=x, weight=weight, bias=weights.pop(prefix + ".bias"), pad_type="same")

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, side, side))], opset_version=ct.target.macOS13)
    def program(image):
        value = convolution(image, "feats.0")
        for number in range(1, 29):
            name = f"feats.{number}"
            mixed = convolution(value, name + ".channel_mixer.0")
            mixed = mb.mul(x=mixed, y=mb.tanh(x=mb.softplus(x=mixed)))
            mixed = convolution(mixed, name + ".channel_mixer.2")
            local, remaining = mb.split(x=mixed, axis=1, split_sizes=[16, 48])
            mixed = mb.concat(values=[convolution(local, name + ".lk.conv"), remaining], axis=1)
            mask = mb.sigmoid(x=convolution(mixed, name + ".attn.f.0"))
            mixed = convolution(mb.mul(x=mixed, y=mask), name + ".refine")
            groups = mb.reshape(x=mixed, shape=[1, 4, 16 * side, side])
            normalized = mb.instance_norm(x=groups, epsilon=1.0e-5)
            mixed = mb.reshape(x=normalized, shape=[1, 64, side, side])
            gain = weights.pop(name + ".norm.weight").reshape(1, 64, 1, 1)
            offset = weights.pop(name + ".norm.bias").reshape(1, 64, 1, 1)
            mixed = mb.add(x=mb.mul(x=mixed, y=gain), y=offset)
            value = mb.add(x=value, y=mixed)
        return mb.add(x=image, y=convolution(value, "feats.30"), name="restored")

    if weights:
        raise ValueError(f"Unconsumed checkpoint tensors: {list(weights)}")
    model = ct.convert(program, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                       minimum_deployment_target=ct.target.macOS13, skip_model_load=True)
    model.author = "Philip Hofmann (Phips). Core ML conversion by RAWMaster."
    model.license = "CC BY 4.0, https://creativecommons.org/licenses/by/4.0/"
    model.short_description = "1xDeNoise_realplksr_otf. Normalized display RGB photo input and output."
    model.user_defined_metadata["upstream"] = f"https://huggingface.co/Phips/1xDeNoise_realplksr_otf/tree/{REVISION}"
    model.user_defined_metadata["checkpoint_sha256"] = SHA256
    model.save(str(destination))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("weights", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--side", type=int, choices=[64, 96, 128, 192, 256, 384], default=128)
    args = parser.parse_args()
    convert(tensors(args.weights), args.side, args.destination)
