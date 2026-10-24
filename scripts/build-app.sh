#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  print -u2 'Usage: scripts/build-app.sh [release|debug]'
  exit 2
fi
swift build --configuration "$configuration" --jobs 4
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
app="$PWD/output/RAWMaster.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/RAWMaster" "$app/Contents/MacOS/RAWMaster"
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
./scripts/build-icons.sh "$app/Contents/Resources"
python3 scripts/check-app-icon.py "$app"
codesign --force --sign - "$app"
print "Built $app"
print "Open with: open '$app'"
