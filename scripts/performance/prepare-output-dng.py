#!/usr/bin/env python3
"""Derive two photographic LinearRaw DNGs that differ only in ColorimetricReference."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image
import tifffile


def make_pair(jpeg, directory):
    directory.mkdir(parents=True, exist_ok=True)
    width, height = 480, 320
    with Image.open(jpeg) as source:
        photo = source.convert("RGB").resize((width, height), Image.Resampling.LANCZOS)
    preview = np.asarray(photo.resize((96, 64), Image.Resampling.BILINEAR))
    srgb = np.asarray(photo).astype(np.float32) / 255
    linear = np.rint(np.where(srgb <= .04045, srgb / 12.92, ((srgb + .055) / 1.055) ** 2.4) * 65535).astype(np.uint16)
    # XYZ D50 to linear sRGB, as DNG ColorMatrix1 signed rational coefficients.
    matrix = (3.1338561,-1.6168667,-.4906146,-.9787684,1.9161415,.033454,.0719453,-.2289914,1.4052427)
    rational = tuple(value for entry in matrix for value in (round(entry * 100000), 100000))
    sensor = [(50714,"H",3,(0,0,0),False),(50717,"I",1,65535,False),
              (50718,"2I",2,(1,1,1,1),False),(50719,"I",2,(0,0),False),
              (50720,"I",2,(width,height),False),(50829,"I",4,(0,0,height,width),False)]
    for reference in (0, 1):
        tags = [(271,"s",0,"RAWMaster",False),(272,"s",0,"RGB reference",False),(274,"H",1,1,False),
                (50706,"B",4,(1,4,0,0),False),(50707,"B",4,(1,1,0,0),False),
                (50708,"s",0,"RAWMaster RGB reference",False),(50879,"H",1,reference,False),
                (50721,"2i",9,rational,False),(50778,"H",1,23,False),(50728,"2I",3,(1,1,1,1,1,1),False)]
        path = directory / f"preview-reference-{reference}.dng"
        with path.open("xb") as stream, tifffile.TiffWriter(stream) as writer:
            writer.write(preview, photometric="rgb", metadata=None, extratags=tags, subifds=1, subfiletype=1)
            writer.write(linear, photometric=34892, planarconfig="contig", metadata=None, extratags=sensor, subfiletype=0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("camera_jpeg", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    make_pair(args.camera_jpeg, args.output_directory)
