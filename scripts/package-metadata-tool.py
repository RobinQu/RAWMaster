#!/usr/bin/env python3
"""Package the pinned local upstream closure; build-time Python only, no network."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

COMMIT = "2200871d9cef988051d2a99d67df3bda6cbb30a8"

def owned_destination(destination):
    if destination.is_symlink() or not destination.is_dir():
        raise ValueError("Existing destination is not an owned tool directory")
    manifest = json.loads((destination / "manifest.json").read_text())
    files = manifest.get("files", {})
    if manifest.get("version") != "13.59" or manifest.get("commit") != COMMIT or len(files) < 100:
        raise ValueError("Existing destination has no owned tool manifest")
    expected = set(files) | {"manifest.json"}
    actual = set()
    expected_directories = {str(parent) for name in files for parent in pathlib.PurePosixPath(name).parents if str(parent) != "."}
    for path in destination.rglob("*"):
        if path.is_symlink():
            raise ValueError("Existing tool destination contains a symlink")
        if path.is_dir() and path.relative_to(destination).as_posix() not in expected_directories:
            raise ValueError("Existing tool destination contains unowned directories")
        if path.is_file():
            actual.add(path.relative_to(destination).as_posix())
    if actual != expected:
        raise ValueError("Existing tool destination contains unowned files")
    for name, expected_hash in files.items():
        parts = pathlib.PurePosixPath(name).parts
        if not parts or name.startswith("/") or any(part in (".", "..") for part in parts):
            raise ValueError("Unsafe prior manifest path")
        if hashlib.sha256((destination / name).read_bytes()).hexdigest() != expected_hash:
            raise ValueError("Existing tool destination changed")
    closure = "".join(name + "\0" + files[name] + "\n" for name in sorted(files))
    if hashlib.sha256(closure.encode()).hexdigest() != manifest.get("closureSHA256"):
        raise ValueError("Existing tool destination closure mismatch")


def package(source, destination):
    source = source.resolve(strict=True)
    if destination.is_symlink() or any(parent.is_symlink() for parent in destination.parents):
        raise ValueError("Destination path contains a symlink")
    destination = destination.absolute()
    resolved = destination.resolve()
    if resolved == source or source in resolved.parents or resolved in source.parents:
        raise ValueError("Source and destination must be disjoint")
    if destination.exists():
        owned_destination(destination)
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() != COMMIT:
        raise ValueError("ExifTool commit mismatch")
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source, text=True).strip():
        raise ValueError("ExifTool source must be clean")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(tempfile.mkdtemp(prefix=".metadata-tool-", dir=destination.parent))
    target_root = staging
    try:
        tracked = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", "HEAD", "--", "exiftool", "README", "LICENSE", "lib/"], cwd=source, text=True).splitlines()
        if not {"exiftool", "README", "LICENSE", "lib/Image/ExifTool.pm"}.issubset(tracked):
            raise ValueError("Pinned source closure incomplete")
        selected = [source / name for name in tracked]
        files = {}
        for path in selected:
            if path.is_symlink():
                raise ValueError("Tool closure contains a symlink")
            if not path.is_file():
                continue
            relative = path.relative_to(source).as_posix()
            committed = subprocess.check_output(["git", "rev-parse", "HEAD:" + relative], cwd=source, text=True).strip()
            disk_blob = subprocess.check_output(["git", "hash-object", "--no-filters", "--", relative], cwd=source, text=True).strip()
            if committed != disk_blob:
                raise ValueError("Pinned source file differs from committed blob")
            target = target_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            files[relative] = hashlib.sha256(target.read_bytes()).hexdigest()
        closure = "".join(name + "\0" + files[name] + "\n" for name in sorted(files))
        manifest = {"version": "13.59", "commit": COMMIT, "closureSHA256": hashlib.sha256(closure.encode()).hexdigest(), "files": files}
        (target_root / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        if destination.exists():
            # Recheck immediately before deleting only the verified, wholly owned closure.
            owned_destination(destination)
            shutil.rmtree(destination)
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--destination", type=pathlib.Path, required=True)
    args = parser.parse_args()
    package(args.source, args.destination)
