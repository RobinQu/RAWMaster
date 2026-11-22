"""Link the native provider acceptance driver to an existing macOS debug build. No model or network access."""
import argparse
from pathlib import Path
import platform
import shutil
import subprocess


def build(products, out):
    products = products.resolve()
    out = out.resolve()
    source = Path(__file__).resolve().with_name("provider-probe.swift")
    root = source.parents[3]
    objects = []
    for target in ("RAWMasterAI", "RAWMasterCore", "RAWMasterPhotoExport"):
        combined = products / (target + ".o")
        items = [combined] if combined.is_file() else sorted((products / (target + ".build")).glob("*.o"))
        if not items and target in ("RAWMasterAI", "RAWMasterCore"):
            raise SystemExit(f"Missing compiled {target} in {products}. Build RAWMaster for macOS first.")
        objects.extend(items)
    out.mkdir(parents=True, exist_ok=True)
    bundle = products / "RAWMaster_RAWMasterAI.bundle"
    shutil.copytree(bundle, out / bundle.name, dirs_exist_ok=True)
    argv = ["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine() + "-apple-macosx15.0",
            "-I", str(products), "-I", str(products / "Modules"),
            "-Xcc", "-fmodule-map-file=" + str(root / "Sources/CSQLite/module.modulemap"),
            str(source), *map(str, objects), "-lsqlite3", "-o", str(out / "provider-probe")]
    subprocess.run(argv, check=True)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--products", type=Path, required=True)
    cli.add_argument("--out", type=Path, required=True)
    args = cli.parse_args()
    build(args.products, args.out)
