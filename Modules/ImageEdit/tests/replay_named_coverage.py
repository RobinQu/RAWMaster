#!/usr/bin/env python3
"""Replay the native frozen-mask fixture through the production raster C ABI."""
import argparse
import array
import ctypes as c
import hashlib
import json
import sys
import time
from pathlib import Path


class Coverage(c.Structure):
    _fields_ = [("id", c.c_char_p), ("id_bytes", c.c_size_t),
                ("values", c.POINTER(c.c_float)), ("count", c.c_size_t)]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_verified(folder, entry, size=None):
    file = folder / entry["filename"]
    if size is not None and file.stat().st_size != size:
        raise ValueError(f"unexpected extent in {file.name}")
    data = file.read_bytes()
    if digest(data) != entry["sha256"]:
        raise ValueError(f"digest mismatch for {file.name}")
    return data


def open_runtime(binary):
    library = c.CDLL(str(binary.resolve()))
    library.rm_image_abi_version.argtypes = []
    library.rm_image_abi_version.restype = c.c_uint32
    if library.rm_image_abi_version() != 1:
        raise ValueError("unexpected image ABI")
    library.rm_image_plan_open_v2.argtypes = [c.c_char_p, c.c_size_t, c.c_char_p, c.c_size_t,
                                             c.c_uint32, c.POINTER(c.c_void_p)]
    library.rm_image_plan_open_v2.restype = c.c_int32
    library.rm_image_plan_render_v2.argtypes = [c.c_void_p, c.c_uint32, c.c_uint32, c.POINTER(c.c_float),
        c.c_size_t, c.POINTER(Coverage), c.c_size_t, c.POINTER(c.c_float), c.c_size_t]
    library.rm_image_plan_render_v2.restype = c.c_int32
    library.rm_image_plan_close_v1.argtypes = [c.c_void_p]
    library.rm_image_plan_close_v1.restype = None
    return library


def make_plan(library, recipe, resources, backend):
    path = str(resources.resolve()).encode()
    handle = c.c_void_p()
    status = library.rm_image_plan_open_v2(recipe, len(recipe), path, len(path), backend, c.byref(handle))
    if status or not handle.value:
        raise RuntimeError(f"rm_image_plan_open_v2 returned {status}")
    return handle


def render(library, handle, width, height, source, named):
    output = (c.c_float * len(source))()
    start = time.monotonic_ns()
    status = library.rm_image_plan_render_v2(handle, width, height, source, len(source),
                                              named, len(named), output, len(output))
    elapsed = (time.monotonic_ns() - start) / 1_000_000
    if status:
        raise RuntimeError(f"rm_image_plan_render_v2 returned {status}")
    return bytes(output), elapsed


def report_pixels(rendered, base, comparison, masks):
    actual_bits = memoryview(rendered).cast("I")
    base_bits = memoryview(base).cast("I")
    counts = {"neither": 0, "firstOnly": 0, "secondOnly": 0, "both": 0, "protectedMismatches": 0}
    for i, (first, second) in enumerate(zip(*masks)):
        start = 4 * i
        if first == 0 and second == 0:
            counts["neither"] += 1
            if actual_bits[start:start + 4] != base_bits[start:start + 4]:
                counts["protectedMismatches"] += 1
        elif second == 0:
            counts["firstOnly"] += 1
        elif first == 0:
            counts["secondOnly"] += 1
        else:
            counts["both"] += 1
    if counts["protectedMismatches"] or not all(counts[key] for key in ("neither", "firstOnly", "both")):
        raise ValueError(f"the fixture did not preserve all protected pixels and exercise both masks: {counts}")
    actual = memoryview(rendered).cast("f")
    reference = memoryview(comparison).cast("f")
    max_delta = max(abs(a - b) for a, b in zip(actual, reference))
    return counts | {"maximumDeltaFromMacOSCPU": max_delta}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("binary", type=Path)
    parser.add_argument("resources", type=Path)
    parser.add_argument("--backend", choices=("cpu", "gpu"), required=True)
    parser.add_argument("--pixels", type=Path)
    args = parser.parse_args()
    if sys.byteorder != "little" or array.array("f").itemsize != 4:
        raise ValueError("the replay expects little-endian FP32")
    manifest = json.loads((args.folder / "manifest.json").read_bytes())
    w, h = manifest["width"], manifest["height"]
    count = w * h
    source = (c.c_float * (4 * count)).from_buffer_copy(read_verified(args.folder, manifest["frame"], 16 * count))
    atlas_file = args.resources / manifest["film"]["filename"]
    if digest(atlas_file.read_bytes()) != manifest["film"]["sha256"]:
        raise ValueError("film atlas digest mismatch")
    planes = manifest["planes"]
    if [plane["role"] for plane in planes] != ["sky", "subject"]:
        raise ValueError("unexpected two-mask fixture roles")
    samples = [(c.c_float * count).from_buffer_copy(read_verified(args.folder, plane, 4 * count)) for plane in planes]
    ids = [plane["id"].encode() for plane in planes]
    # Reverse the host descriptors to exercise named binding through the foreign interface.
    named = (Coverage * 2)(*(Coverage(ids[i], len(ids[i]), samples[i], count) for i in reversed(range(2))))
    recipe = read_verified(args.folder, manifest["recipe"])
    comparison = read_verified(args.folder, manifest["cpu"], 16 * count)
    library = open_runtime(args.binary)
    backend = int(args.backend == "gpu")
    plan = make_plan(library, recipe, args.resources, backend)
    try:
        output, elapsed = render(library, plan, w, h, source, named)
    finally:
        library.rm_image_plan_close_v1(plan)

    base = read_verified(args.folder, manifest["base"], 16 * count)
    if backend:
        version = json.loads(recipe)
        base_nodes = [node for node in version["nodes"] if node["op"] in ("source", "photo_filter")]
        [film] = [node for node in base_nodes if node["op"] == "photo_filter"]
        base_recipe = json.dumps(version | {"output": film["id"], "nodes": base_nodes}).encode()
        plan = make_plan(library, base_recipe, args.resources, backend)
        try:
            base, _ = render(library, plan, w, h, source, (Coverage * 0)())
        finally:
            library.rm_image_plan_close_v1(plan)
    counts = report_pixels(output, base, comparison, samples)
    if (backend and counts["maximumDeltaFromMacOSCPU"] > 8e-6) or (not backend and output != comparison):
        raise ValueError(f"cross-host pixel discrepancy: {counts}")
    if args.pixels:
        args.pixels.write_bytes(output)
    print(json.dumps({"backend": args.backend, "extent": [w, h], "sourceSHA256": manifest["sourceSHA256"],
        "recipeSHA256": digest(recipe), "rgbaSHA256": digest(output), "baseSHA256": digest(base),
        "macOSCPUSHA256": digest(comparison), "renderMs": elapsed, "reversedBindings": True,
        "inputs": planes, **counts}, indent=2))


if __name__ == "__main__":
    main()
