#!/usr/bin/env python3
"""Build the bundled FLUX.3 Klein model manifest from the reviewed release manifest."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "output/research/flux3-klein/models/q8/release-manifest.json"
DEST = ROOT / "Sources/RAWMasterAI/Resources/FluxModelManifest.json"
REVISION = "d9790a1ceaba200e8b773fb236f7c9fa754283a7"
REPO = "devin-lai/flux-3-image-klein-mlx-q8"


def main():
    release = json.loads(SOURCE.read_text())
    files = [
        {"path": name, "bytes": row["bytes"], "sha256": row["sha256"]}
        for name, row in sorted(release["files"].items())
    ]
    total = sum(row["bytes"] for row in files)
    manifest = {
        "schemaVersion": 1,
        "repoID": REPO,
        "revision": REVISION,
        "modelID": "black-forest-labs/flux-3-image-klein",
        "license": "FLUX Kommunity License v.1.0",
        "licenseURL": f"https://huggingface.co/{REPO}/blob/{REVISION}/LICENSE.md",
        "totalBytes": total,
        "files": files,
    }
    DEST.parent.mkdir(parents=True, exist_ok=True)
    DEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{DEST}: {len(files)} files, {total} bytes")


if __name__ == "__main__":
    main()
