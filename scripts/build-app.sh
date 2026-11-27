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
typeset -a swift_build_options
swift_build_options=(--configuration "$configuration")
if [[ -n "${RAWMASTER_BUILD_PATH:-}" ]]; then
  swift_build_options+=(--scratch-path "$RAWMASTER_BUILD_PATH")
fi
flux_worker_root="$PWD/Modules/FluxWorker"
flux_worker_binary="$PWD/Sources/RAWMasterAI/Resources/FluxWorker/flux-worker"
"$flux_worker_root/build-worker.sh" "$flux_worker_root" "$flux_worker_root/target" "$flux_worker_binary"
swift build "${swift_build_options[@]}" --jobs 4 --product RAWMaster
binary_dir="$(swift build "${swift_build_options[@]}" --show-bin-path)"
app="${RAWMASTER_APP_OUTPUT:-$PWD/output/RAWMaster.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/RAWMaster" "$app/Contents/MacOS/RAWMaster"
/usr/bin/ditto "$binary_dir/RAWMaster_RAWMaster.bundle" "$app/Contents/Resources/RAWMaster_RAWMaster.bundle"
/usr/bin/ditto "$binary_dir/PhotoExport_RAWMasterPhotoExport.bundle" "$app/Contents/Resources/PhotoExport_RAWMasterPhotoExport.bundle"
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
if len(value['looks'])!=9 or len(planes)!=36 or len(expected)!=37 or {p.name for p in root.iterdir()}!=expected|{'Spektrafilm'}:
    raise SystemExit('Unexpected photo-filter resource inventory')
for plane in planes:
    name=plane['file'];path=root/name
    if Path(name).name!=name or path.is_symlink() or not path.is_file() or path.stat().st_size!=plane['byteCount'] or sha(path)!=plane['sha256']:
        raise SystemExit('Photo-filter payload integrity failure: '+name)
film=root/'Spektrafilm'
if film.is_symlink() or not film.is_dir():
    raise SystemExit('Missing film simulation assets')
film_catalog=film/'catalog-v1.json'
film_license=film/'SPEKTRAFILM_LICENSE.txt'
if (film_catalog.is_symlink() or sha(film_catalog)!='73c220dfae5e1a88abf219f48977c58ac7014f70f57ee7e77342b0c4a84644ed'
        or film_license.is_symlink() or sha(film_license)!='76d629501783ae52e8d63aee1e054c1e1a9713b9fe7d36fb306e25b1d14b24e9'):
    raise SystemExit('Unverified film simulation catalog or upstream license')
film_manifest=json.loads(film_catalog.read_text())
film_files={'catalog-v1.json','SPEKTRAFILM_LICENSE.txt','CHANGELOG.txt','provenance.json'}
if sha(film/'provenance.json')!=film_manifest['sourceBindingsSHA256'] or sha(film/'CHANGELOG.txt')!='2179a59961e90f834ffe213e6609c6d5e530b8a35d97a9cfe595f8b5282e53d5':
    raise SystemExit('Missing film simulation attribution or provenance')
for look in film_manifest['looks']:
    plane,=look['planes']
    path=film/plane['file']
    if path.name!=plane['file'] or path.stat().st_size!=plane['byteCount'] or sha(path)!=plane['sha256']:
        raise SystemExit('Film LUT failed integrity verification: '+path.name)
    film_files.add(path.name)
if {p.name for p in film.iterdir()}!=film_files or any(p.is_symlink() or not p.is_file() for p in film.iterdir()):
    raise SystemExit('Unexpected film simulation resource inventory')
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
catalog_bundle="$binary_dir/LibraryCatalog_RAWMasterLibrary.bundle"
catalog_runtime="$catalog_bundle/Contents/Resources/rawmaster-library.runtime"
test -f "$catalog_runtime"
mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/LibraryNotices"
Modules/LibraryCatalog/GroupRender/build.sh "$app/Contents/Helpers/rawmaster-group-render"
cp Modules/LibraryCatalog/GroupRender/OpenCV-LICENSE.txt "$app/Contents/Resources/LibraryNotices/"
install -m 0644 "${RAWMASTER_BUILD_PATH:-$PWD/.build}/checkouts/SimpleToast/LICENSE" "$app/Contents/Resources/LibraryNotices/SimpleToast-LICENSE.txt"
discovery_pack="${RAWMASTER_LIBRARY_DISCOVERY_PACK:-$PWD/output/library-models/LibraryDiscovery}"
if [[ -d "$discovery_pack" ]]; then
  python3 - "$discovery_pack" Modules/LibraryCatalog/Swift/Resources/discovery/models.json <<'DISCOVERY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
pins = json.loads(pathlib.Path(sys.argv[2]).read_text())
runtime = json.loads((root / 'runtime.json').read_text())
for field in ['sceneModel','faceModel']:
    if runtime[field] != pins[field]:
        raise SystemExit('Unexpected library discovery model ' + field)
for name, expected in pins['sha256'].items():
    with (root / 'models' / name).open('rb') as f:
        if hashlib.file_digest(f,'sha256').hexdigest() != expected:
            raise SystemExit('Library model digest mismatch for ' + name)
if not (root / 'runtime/bin/python3.12').is_file() or not (root / 'discovery/worker.py').is_file():
    raise SystemExit('Incomplete library discovery runtime')
DISCOVERY
  ditto "$discovery_pack" "$app/Contents/Resources/LibraryDiscovery"
elif [[ -n "${RAWMASTER_LIBRARY_DISCOVERY_PACK:-}" ]]; then
  print -u2 "Missing requested library model bundle: $discovery_pack"
  exit 1
fi
codesign --force --sign - "$app/Contents/Helpers/rawmaster-group-render"
mkdir -p "$app/Contents/Frameworks"
cp "$catalog_runtime" "$app/Contents/Frameworks/librawmaster_library.dylib"
image_runtime="$binary_dir/ImageEdit_RAWMasterImage.bundle/Contents/Resources/rawmaster-image.runtime"
test -f "$image_runtime"
/usr/bin/codesign --verify "$image_runtime"
cp "$image_runtime" "$app/Contents/Frameworks/librawmaster_image.dylib"
/usr/bin/codesign --verify "$app/Contents/Frameworks/librawmaster_image.dylib"
ditto "$catalog_bundle" "$app/Contents/Resources/LibraryCatalog_RAWMasterLibrary.bundle"
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
<key>CFBundleDocumentTypes</key>
<array><dict>
  <key>CFBundleTypeName</key><string>RAWMaster 资料库</string>
  <key>CFBundleTypeIconFile</key><string>LibraryFolder.icns</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSHandlerRank</key><string>Owner</string>
  <key>LSItemContentTypes</key><array><string>io.robinqu.rawmaster.library</string></array>
</dict></array>
<key>UTExportedTypeDeclarations</key>
<array><dict>
  <key>UTTypeIdentifier</key><string>io.robinqu.rawmaster.library</string>
  <key>UTTypeDescription</key><string>RAWMaster 资料库</string>
  <key>UTTypeIconFile</key><string>LibraryFolder.icns</string>
  <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.content</string></array>
  <key>UTTypeTagSpecification</key><dict>
    <key>public.filename-extension</key><array><string>rawmasterlibrary</string></array>
  </dict>
</dict></array>
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
