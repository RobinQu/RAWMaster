#!/usr/bin/env python3
"""Regenerate the independent Spec 037 CPU oracle with OpenColorIO 2.5.0."""
import argparse
import hashlib
import json
from pathlib import Path

import PyOpenColorIO as ocio

CONFIG = 'studio-config-v4.0.0_aces-v2.0_ocio-v2.5'
VERSION = '2.5.0'
DIGEST = '3a48b0421e51d4284ec07187f86b74387321550b65f5a2f237885bf269dbc99e'
NAMES = {'linearRec709': 'Linear Rec.709 (sRGB)', 'aces2065': 'ACES2065-1', 'acescg': 'ACEScg'}
COLORS = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (0.18, 0.18, 0.18),
          (-0.25, 0.0625, 3.25), (2.0, -0.5, -0.125), (8, 12, 2), (0.001, 0.002, 0.008)]


def reference():
    if ocio.__version__ != VERSION:
        raise SystemExit(f'Expected OCIO {VERSION}, got {ocio.__version__}')
    config = ocio.Config.CreateFromBuiltinConfig(CONFIG)
    digest = hashlib.sha256(config.serialize().encode()).hexdigest()
    if digest != DIGEST:
        raise SystemExit(f'Unexpected OCIO config SHA-256: {digest}')
    vectors = []
    for source, target in [('linearRec709', 'acescg'), ('aces2065', 'acescg'),
                           ('acescg', 'aces2065'), ('acescg', 'acescg')]:
        processor = config.getProcessor(NAMES[source], NAMES[target]).getDefaultCPUProcessor()
        for index, rgb in enumerate(COLORS):
            for alpha, opacity, scale, ev in [('straight', 1, 1, 0), ('straight', 0.25, 0.5, 4),
                                             ('premultiplied', 0.25, 2, -2), ('straight', 0, 1, 1)]:
                pixel = [component * opacity if alpha == 'premultiplied' else component for component in rgb]
                exposed = [component * scale * 2**ev for component in rgb]
                expected = [value * opacity for value in processor.applyRGB(exposed)]
                vectors.append(dict(source=source, target=target, sample=index, input=pixel + [opacity],
                                    alpha=alpha, scale=scale, ev=ev, output=expected + [opacity]))
    # One vector per line keeps the fixture compact and easy to diff.
    header = dict(version=VERSION, config=CONFIG, configSHA256=digest)
    text = json.dumps(header, indent=2)[:-2] + ',\n  "vectors": [\n'
    return (text + ',\n'.join('    ' + json.dumps(vector, allow_nan=False) for vector in vectors) + '\n  ]\n}\n').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', type=Path, help='Compare against an existing fixture; do not change it.')
    args = parser.parse_args()
    data = reference()
    if args.check is not None:
        if args.check.read_bytes() != data:
            raise SystemExit('The scene-color fixture does not match the fixed OCIO reference')
        print('Matched all 128 fixed OCIO scene-color vectors.')
    else:
        print(data.decode(), end='')


if __name__ == '__main__':
    main()
