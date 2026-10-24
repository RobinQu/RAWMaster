#!/usr/bin/env python3
"""Validate the shipping catalog, including the actual compiled appearance mapping."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess


def check(app):
    resources = app / "Contents/Resources"
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIconName") != "AppIcon":
        raise ValueError("CFBundleIconName must point to AppIcon")
    if info.get("CFBundleIconFile") != "AppIcon" or not (resources / "AppIcon.icns").is_file():
        raise ValueError("Missing legacy AppIcon.icns fallback")
    result = subprocess.run(
        ["xcrun", "assetutil", "--info", str(resources / "Assets.car")],
        check=True, capture_output=True, text=True,
    )
    catalog = json.loads(result.stdout)
    report = {"app": str(app), "appearances": {}}
    digests = []
    for appearance, artwork in [("NSAppearanceNameAqua", "LightMinimal"), ("NSAppearanceNameDarkAqua", "DarkMinimal")]:
        stacks = [item for item in catalog if item.get("AssetType") == "IconImageStack"
                  and item.get("Name") == "AppIcon" and item.get("Appearance") == appearance]
        if not stacks:
            raise ValueError(f"Missing native icon stack for {appearance}")
        groups = [item for item in catalog if item.get("AssetType") == "IconGroup"
                  and item.get("Name", "").startswith("AppIcon/") and item.get("Appearance") == appearance]
        active = [layer for group in groups for layer in group.get("Layers", [])
                  if layer.get("LayerOpacity", 1) > 0]
        if len(active) != 1 or active[0].get("Name") != f"AppIcon_Assets/{artwork}":
            raise ValueError(f"Wrong compiled artwork for {appearance}: {active}")
        layer = active[0]
        if min(layer.get("PixelWidth", 0), layer.get("PixelHeight", 0)) < 1024:
            raise ValueError(f"Insufficient icon resolution for {appearance}")
        digest = layer["SHA1Digest"]
        digests.append(digest)
        report["appearances"][appearance] = {"artwork": artwork, "sha": digest}
    if digests[0] == digests[1]:
        raise ValueError("Light and dark must contain different artwork")
    fallback = [item for item in catalog if item.get("AssetType") == "MultiSized Image"
                and item.get("Name") == "AppIcon"]
    if not fallback or len(fallback[0].get("Sizes", [])) < 7:
        raise ValueError("Missing small-size or high-resolution legacy icon renditions")
    report["fallback_sizes"] = fallback[0]["Sizes"]
    subprocess.run([
        "swift", str(Path(__file__).with_name("prepare-dock-icons.swift")), "--check",
        str(resources / "DockIcon-Light.png"), str(resources / "DockIcon-Dark.png"),
    ], check=True)
    report["dock_layout"] = {"canvas": 1024, "body": 824, "inset": 100}
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = check(args.app.resolve())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"App icon validation failed: {error}\n")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print("App icon passed: light C2, dark C1, native appearance stacks and legacy sizes.")
