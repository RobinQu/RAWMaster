#!/usr/bin/env python3
"""Verify a sealed 044 local RAW application and inventory its exact payload."""
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


MAIN = "Contents/MacOS/RAWMaster"
FRAMEWORKS = "Contents/Frameworks/"
LIBRARIES = {
    "libflashraw_capi.dylib",
    "librawmaster_image.dylib",
    "librawmaster_library.dylib",
    "librawmaster_photo_export.dylib",
}
MACH_O = {
    bytes.fromhex(magic)
    for magic in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
}
SYSTEM_PREFIXES = ("/System/Library/", "/usr/lib/")
DYLIB_COMMANDS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}
REQUIRED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.files.bookmarks.app-scope": True,
}


def result(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect_binary(binary, library):
    if result("lipo", "-archs", binary).strip() != b"arm64":
        raise ValueError(f"Expected an arm64 Mach-O: {binary.name}")
    load_commands = []
    for block in result("otool", "-l", binary).decode().split("Load command ")[1:]:
        fields = re.findall(r"^\s*(cmd|platform|minos|path|name)\s+(.*?)\s*(?:\(offset \d+\))?$", block, re.MULTILINE)
        load_commands.append(dict(fields))
    builds = [row for row in load_commands if row.get("cmd") == "LC_BUILD_VERSION"]
    if len(builds) != 1 or builds[0].get("platform") not in ("1", "macos"):
        raise ValueError(f"Unexpected platform load command: {binary.name}")
    minimum = builds[0]["minos"]
    version = tuple(int(part) for part in minimum.split("."))
    if not version or (version + (0, 0))[:3] > (15, 0, 0):
        raise ValueError(f"{binary.name} requires macOS {minimum}")
    rpaths = [row["path"] for row in load_commands if row.get("cmd") == "LC_RPATH"]
    if set(rpaths) - {"/usr/lib/swift", "@loader_path", "@executable_path/../Frameworks"}:
        raise ValueError(f"Unexpected runtime search path: {binary.name}")
    names = [row["name"] for row in load_commands if row.get("cmd") == "LC_ID_DYLIB"]
    if names != ([f"@rpath/{binary.name}"] if library else []):
        raise ValueError(f"Unexpected install name: {binary.name}")
    dependencies = [row["name"] for row in load_commands if row.get("cmd") in DYLIB_COMMANDS]
    bundled = {f"@rpath/{name}" for name in LIBRARIES}
    for name in dependencies:
        if not name.startswith(SYSTEM_PREFIXES) and name not in bundled:
            raise ValueError(f"{binary.name} has an unresolved dependency: {name}")
    in_bundle_rpaths = {"@executable_path/../Frameworks"}
    if library:
        in_bundle_rpaths.add("@loader_path")
    if bundled.intersection(dependencies) and not in_bundle_rpaths.intersection(rpaths):
        raise ValueError(f"{binary.name} has a bundled dependency but no in-bundle rpath")
    result("codesign", "--verify", "--strict", binary)
    if library and result("codesign", "-d", "--entitlements", "-", "--xml", binary).strip():
        raise ValueError(f"Unexpected embedded entitlements: {binary.name}")
    return {"architecture": "arm64", "minimumMacOS": minimum, "installName": names[0] if names else None,
            "rpaths": rpaths, "dependencies": dependencies}


def verify(app, channel, flashraw_input):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleIdentifier"] != f"io.robinqu.RAWMaster.{channel}"
            or info["RAWMasterDistributionChannel"] != channel or info["LSMinimumSystemVersion"] != "15.0"
            or info["CFBundleExecutable"] != "RAWMaster"):
        raise ValueError("Application info does not match its local channel")
    result("codesign", "--verify", "--deep", "--strict", app)
    entitlements = plistlib.loads(result("codesign", "-d", "--entitlements", "-", "--xml", app))
    if entitlements != REQUIRED_ENTITLEMENTS:
        raise ValueError("Application entitlements do not match the local RAW capability profile")

    expected = {MAIN} | {FRAMEWORKS + filename for filename in LIBRARIES}
    payload = []
    code = {}
    for path in sorted(app.rglob("*")):
        name = path.relative_to(app).as_posix()
        if path.is_symlink():
            raise ValueError(f"Unexpected symlink: {name}")
        if path.is_dir():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in MACH_O:
            if name not in expected:
                raise ValueError(f"Unexpected code in the application payload: {name}")
            code[name] = inspect_binary(path, name != MAIN)
        elif magic.startswith(b"#!") or path.suffix.lower() in {".py", ".pl", ".zip", ".provisionprofile"}:
            raise ValueError(f"Unexpected script, external runtime or profile: {name}")
        payload.append({"path": name, "bytes": path.stat().st_size, "sha256": digest(path)})
    if set(code) != expected:
        raise ValueError(f"Application is missing code: {sorted(expected - set(code))}")

    signature = subprocess.run(["codesign", "-dvvv", app], check=True, capture_output=True, text=True).stderr
    cdhash = re.search(r"^CDHash=(\w+)$", signature, re.MULTILINE)
    if "Signature=adhoc" not in signature or not cdhash:
        raise ValueError("Expected an ad-hoc application signature")
    locks = [Path("Package.resolved"), *(Path("Modules") / name / "Cargo.lock"
             for name in ("CoreAI", "ImageEdit", "LibraryCatalog", "PhotoExport"))]
    manifest = {
        "channel": channel, "bundleIdentifier": info["CFBundleIdentifier"], "buildVersion": info["CFBundleVersion"],
        "shortVersion": info["CFBundleShortVersionString"], "minimumMacOS": info["LSMinimumSystemVersion"],
        "sourceCommit": result("git", "rev-parse", "HEAD").decode().strip(),
        "trackedSourceModified": bool(result("git", "status", "--porcelain", "--untracked-files=no").strip()),
        "buildInputs": {"lockfileSHA256": {str(path): digest(path) for path in locks},
                        "flashRawInputSHA256": digest(flashraw_input)},
        "signature": {"identity": "ad-hoc", "cdhash": cdhash[1], "entitlements": entitlements},
        "code": code, "payload": payload,
    }
    (app.parent / "app-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Verified {channel}: {len(code)} arm64 binaries and {len(payload)} sealed payload files")


if __name__ == "__main__":
    app, channel, flashraw_input = sys.argv[1:]
    try:
        verify(Path(app), channel, Path(flashraw_input))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
