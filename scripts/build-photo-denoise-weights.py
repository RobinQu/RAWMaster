#!/usr/bin/env python3
"""Pack nagadomi's MIT-licensed vgg_7 photographic denoising weights for Metal Performance Shaders."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import urllib.request

REVISION = "cc385f97a9debfe611316aabfd5d8bb30ba2dbeb"
SOURCE = f"https://raw.githubusercontent.com/nagadomi/waifu2x/{REVISION}/models/vgg_7/photo/noise2_model.json"
SOURCE_SHA256 = "e9476299fc348b3570541925d14a431f0e39e103ad6e16c4421602fde0062f06"
CHANNELS = (3, 32, 32, 64, 64, 128, 128, 3)


def pack(data):
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise ValueError("Incorrect source checkpoint identity")
    layers = json.loads(data)
    output = bytearray()
    for layer, inputs, outputs in zip(layers, CHANNELS, CHANNELS[1:]):
        if (layer["nInputPlane"], layer["nOutputPlane"], layer["kW"], layer["kH"]) != (inputs, outputs, 3, 3):
            raise ValueError("Incorrect layer dimensions")
        # MPSCNN convolutions store each output feature as KY × KX × input feature channels.
        weights = [layer["weight"][o][i][y][x]
                   for o in range(outputs) for y in range(3) for x in range(3) for i in range(inputs)]
        output += struct.pack(f"<{len(weights)}f", *weights)
        output += struct.pack(f"<{outputs}f", *layer["bias"])
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Use a locally cached copy of the pinned JSON weights")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    raw = args.source.read_bytes() if args.source else urllib.request.urlopen(SOURCE, timeout=90).read()
    model = pack(raw)
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_bytes(model)
    print(hashlib.sha256(model).hexdigest(), args.destination)
