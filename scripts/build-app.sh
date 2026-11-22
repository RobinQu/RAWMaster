#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  print -u2 'Usage: scripts/build-app.sh [release|debug]'
  exit 2
fi
flashraw_source="${FLASHRAW_SOURCE_DIR:-$PWD/output/tools/flashraw-src}"
flashraw_target="${FLASHRAW_TARGET_DIR:-$PWD/output/tools/flashraw-target}"
flashraw_library="${FLASHRAW_LIBRARY:-$flashraw_target/release/libflashraw_capi.dylib}"
if [[ ! -f "$flashraw_library" && -z "${FLASHRAW_LIBRARY:-}" ]]; then
  ./scripts/build-flashraw.sh
fi
if [[ ! -f "$flashraw_library" || ! -f "$flashraw_source/LICENSE-MIT" || ! -f "$flashraw_source/LICENSE-APACHE" ]]; then
  print -u2 "Missing FlashRaw library or licenses. Set FLASHRAW_LIBRARY and FLASHRAW_SOURCE_DIR for an external build."
  exit 1
fi
swift build --configuration "$configuration" --jobs 4
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
app="$PWD/output/RAWMaster.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/RAWMaster" "$app/Contents/MacOS/RAWMaster"
depth_resources="$app/Contents/Resources/SceneDepth"
python3 scripts/build-depth-model.py --destination "$depth_resources"
cp "$flashraw_source/LICENSE-APACHE" "$depth_resources/LICENSE-Apache-2.0.txt"
cp scripts/licenses/SceneDepth-NOTICE.txt "$depth_resources/NOTICE.txt"
ai_resources="$binary_dir/RAWMaster_RAWMasterAI.bundle"
if [[ ! -d "$ai_resources" ]]; then
  print -u2 "Missing AI runtime resources: $ai_resources"
  exit 1
fi
rm -rf "$app/Contents/Resources/RAWMaster_RAWMasterAI.bundle"
cp -R "$ai_resources" "$app/Contents/Resources/"
core_resources="$binary_dir/RAWMaster_RAWMasterCore.bundle"
migration_rules="Contents/Resources/AdobePresetMigration-v1.json"
python3 - "$core_resources/$migration_rules" "$PWD/specs/031-preset-browser/contracts/migration-manifest-v1.json" <<'MIGRATION_RULES_PY'
from pathlib import Path
import json, sys
rules_path, fixture_path = map(Path, sys.argv[1:])
rules = json.loads(rules_path.read_bytes())
fixture = json.loads(fixture_path.read_bytes())
expected = [{"path": row["sourceRelativePath"], "sha256": row["sha256"], "bytes": row["bytes"]}
            for row in fixture["entries"] if row["origin"] == "adobeBuiltinAdaptive"]
if len(expected) != 53 or rules != expected:
    raise SystemExit("Camera Raw migration allowlist differs from the reviewed paths, sizes or digests")
MIGRATION_RULES_PY
rm -rf "$app/Contents/Resources/RAWMaster_RAWMasterCore.bundle"
cp -R "$core_resources" "$app/Contents/Resources/"
cmp "$core_resources/$migration_rules" "$app/Contents/Resources/RAWMaster_RAWMasterCore.bundle/$migration_rules"
# The actual Imaging bundle is mandatory in the App; no development-directory fallback.
verify_photo_filter_resources() {
  python3 - "$1/Contents/Resources/PhotoFilters" <<'PHOTO_FILTER_PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1])
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(65536),b''):h.update(block)
    return h.hexdigest()
catalog=root/'catalog-v1.json'
if not catalog.is_file() or catalog.is_symlink() or sha(catalog)!='0a8a0e9aa4fb7dacdf6ad20d12d5f24dda4132c4b7880acd7fab1c28fa6c61f9':
    raise SystemExit('Missing or unverified bundled photo-filter catalog')
value=json.loads(catalog.read_text());planes=[p for look in value['looks'] for p in look['planes']]
expected={'catalog-v1.json'}|{p['file'] for p in planes}
if len(value['looks'])!=9 or len(planes)!=36 or len(expected)!=37 or {p.name for p in root.iterdir()}!=expected:
    raise SystemExit('Unexpected photo-filter resource inventory')
for plane in planes:
    name=plane['file'];path=root/name
    if Path(name).name!=name or path.is_symlink() or not path.is_file() or path.stat().st_size!=plane['byteCount'] or sha(path)!=plane['sha256']:
        raise SystemExit('Photo-filter payload integrity failure: '+name)
photo_denoise = root.parent / 'PhotoDenoise'
model = photo_denoise / 'PhotoVGG7.f32'
if model.is_symlink() or not model.is_file() or sha(model) != '5e999f1d9b9fcaed0cc06e2cf1bcdecac32bf28246909a5f7d927a5b22d764b5':
    raise SystemExit('Missing or changed photographic denoise weights')
for notice in ('LICENSE.txt', 'NOTICE.txt'):
    if not (photo_denoise / notice).is_file():
        raise SystemExit('Missing photographic denoise attribution: ' + notice)
sr = root.parent / 'PhotoSuperResolution'
for relative, checksum in {
    'Manifest.json': '5e1607b8db571fbd00bc44f8a1b7a4a4a3da011c910d46dcff1d076355717157',
    'Data/com.apple.CoreML/model.mlmodel': 'fdf59e85f0033f3bf25ba57af02866baf0d8da189914695930dbb01987298cb8',
    'Data/com.apple.CoreML/weights/weight.bin': '50eccc4411c58e1937f5546d6456506187d32b5c08369c5a6abe28137689c400'
}.items():
    part = sr / 'PhotoUpconv7.mlpackage' / relative
    if not part.is_file() or part.is_symlink() or sha(part) != checksum:
        raise SystemExit('Missing or changed photographic 2x model: ' + relative)
if not all((sr / name).is_file() for name in ('LICENSE.txt', 'NOTICE.txt')):
    raise SystemExit('Missing photographic 2x model attribution')
PHOTO_FILTER_PY
}
imaging_resources="$binary_dir/RAWMaster_RAWMasterImaging.bundle"
if [[ ! -d "$imaging_resources" ]]; then
  print -u2 "Missing Imaging filter resources: $imaging_resources"
  exit 1
fi
verify_photo_filter_resources "$imaging_resources"
rm -rf "$app/Contents/Resources/RAWMaster_RAWMasterImaging.bundle"
cp -R "$imaging_resources" "$app/Contents/Resources/"
verify_photo_filter_resources "$app/Contents/Resources/RAWMaster_RAWMasterImaging.bundle"

mkdir -p "$app/Contents/Resources/FlashRaw"
cp "$flashraw_library" "$app/Contents/Resources/FlashRaw/libflashraw_capi.dylib"
cp "$flashraw_source/LICENSE-MIT" "$flashraw_source/LICENSE-APACHE" "$app/Contents/Resources/FlashRaw/"

runtime_artifacts="${RAWMASTER_RUNTIME_ARTIFACTS_DIR:-$PWD/output/runtime-artifacts}"
# Runtime executables stay inside a data archive until the native installer has
# authenticated them. A packaged app must work without a system Python or uv.
python3 - "$runtime_artifacts" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
catalog = root / 'catalog.json'
expected = '6ae90188e67edc237a0a90ac7bf2d5acf26afcbdff697a4355f599dd9e85ec37'
def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(8*1024*1024), b''):
            result.update(chunk)
    return result.hexdigest()
if not catalog.is_file() or catalog.is_symlink() or sha(catalog) != expected:
    raise SystemExit('Missing or unverified offline runtime catalog. Set RAWMASTER_RUNTIME_ARTIFACTS_DIR to the fixed artifact directory produced by scripts/package-runtime-artifact.py.')
for artifact in json.loads(catalog.read_text())['artifacts']:
    name = artifact['archivePath']
    path = root / name
    if Path(name).name != name or path.is_symlink() or not path.is_file() or path.stat().st_size != artifact['archiveByteCount'] or sha(path) != artifact['archiveSHA256']:
        raise SystemExit('Offline runtime archive failed integrity verification: ' + name)
PY
mkdir -p "$app/Contents/Resources/RuntimeArtifacts"
cp "$runtime_artifacts/catalog.json" "$runtime_artifacts/rawmaster-comfymlx-v4-arm64-py312.zip" "$app/Contents/Resources/RuntimeArtifacts/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleExecutable</key><string>RAWMaster</string>
<key>CFBundleIdentifier</key><string>io.robinqu.RAWMaster</string>
<key>CFBundleName</key><string>RAWMaster</string>
<key>CFBundleDisplayName</key><string>RAWMaster</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>NSSupportsAutomaticTermination</key><false/>
</dict></plist>
PLIST
build_version="${RAWMASTER_BUILD_VERSION:-1}"
if [[ ! "$build_version" =~ '^[0-9A-Za-z._-]+$' ]]; then
  print -u2 'Invalid RAWMASTER_BUILD_VERSION'
  exit 2
fi
plutil -replace CFBundleVersion -string "$build_version" "$app/Contents/Info.plist"
python3 scripts/package-metadata-tool.py --source "$PWD/output/tools/exiftool" --destination "$app/Contents/Resources/MetadataTool"
./scripts/build-icons.sh "$app/Contents/Resources"
python3 scripts/check-app-icon.py "$app"
codesign --force --sign - "$app"
print "Built $app"
print "Open with: open '$app'"
