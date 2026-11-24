"""Check a packaged Mac runtime against its research build without opening a GPU."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


PROBE = {
    "rm_image_half_program_open_probe_v1",
    "rm_image_half_render_probe_v1",
    "rm_image_half_program_close_probe_v1",
}
NATIVE_HALF = {
    "rm_image_metal_half_program_open_v1",
    "rm_image_metal_half_render_v1",
    "rm_image_metal_half_program_close_v1",
}
REQUIRED = {
    "rm_image_abi_version",
    "rm_image_metal_surface_abi_version",
    "rm_image_metal_program_open_v1",
    "rm_image_metal_frame_bind_v1",
    "rm_image_metal_frame_bind_v2",
    "rm_image_metal_frame_render_v1",
    "rm_image_metal_frame_close_v1",
    "rm_image_metal_program_close_v1",
    "rm_image_plan_open_v1",
    "rm_image_plan_open_v2",
    "rm_image_plan_render_v1",
    "rm_image_plan_render_v2",
}


def public_exports(runtime):
    names = subprocess.check_output(["nm", "-gUj", runtime], text=True).splitlines()
    return {name[1:] for name in names if name.startswith("_rm_image_")}


def describe(runtime, symbols):
    return {"path": str(runtime), "sha256": hashlib.sha256(runtime.read_bytes()).hexdigest(),
            "exports": sorted(symbols)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packaged_runtime", type=Path)
    parser.add_argument("probe_runtime", type=Path)
    parser.add_argument("--expect-native-half", action="store_true",
                        help="require the optional production four-band extension")
    args = parser.parse_args()
    packaged = public_exports(args.packaged_runtime)
    probe = public_exports(args.probe_runtime)
    if not REQUIRED <= packaged or any(name.startswith("rm_image_half_") for name in packaged):
        parser.exit(1, "packaged runtime has an unexpected ABI or exposes the research port\n")
    if (args.expect_native_half or packaged & NATIVE_HALF) and not NATIVE_HALF <= packaged:
        parser.exit(1, "the packaged four-band extension requires all three symbols\n")
    if probe != packaged | PROBE:
        parser.exit(1, "the research build must add exactly the three probe symbols\n")
    print(json.dumps({"packaged": describe(args.packaged_runtime, packaged),
                      "probe": describe(args.probe_runtime, probe)}, indent=2))
