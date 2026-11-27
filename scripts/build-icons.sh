#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
resources="${1:?Usage: scripts/build-icons.sh /absolute/path/to/Contents/Resources}"
mkdir -p "$resources"
icon_tmp="$(mktemp -d -t rawmaster-icons)"
trap 'rm -rf -- "$icon_tmp"' EXIT
partial_plist="$icon_tmp/AppIcon.plist"
xcrun actool assets/AppIcon.icon \
  --compile "$resources" \
  --platform macosx --minimum-deployment-target 15.0 --target-device mac \
  --app-icon AppIcon --include-all-app-icons \
  --development-region zh_CN --enable-on-demand-resources NO \
  --output-partial-info-plist "$partial_plist" \
  --output-format human-readable-text --warnings --errors
# Export the approved native renditions, including the system mask.
developer_dir="$(xcode-select -p)"
ictool="${RAWMASTER_ICTOOL:-${developer_dir:h}/Applications/Icon Composer.app/Contents/Executables/ictool}"
if [[ ! -x "$ictool" ]]; then
  print -u2 'Icon Composer ictool is required to export approved Dock icon renditions.'
  exit 1
fi
"$ictool" assets/AppIcon.icon --export-image --output-file "$resources/DockIcon-Light.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 --design-generation 27
"$ictool" assets/AppIcon.icon --export-image --output-file "$resources/DockIcon-Dark.png" \
  --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1 --design-generation 27
# Runtime replacement bypasses the system's macOS icon layout. Add its outer
# canvas space here; keep the native catalog and source layers full-bleed.
swift scripts/prepare-dock-icons.swift "$resources/DockIcon-Light.png" "$resources/DockIcon-Dark.png"

# Finder and the path menu share the same library artwork.
library_source="Sources/RAWMaster/Resources/LibraryFolder.png"
library_iconset="$icon_tmp/LibraryFolder.iconset"
mkdir "$library_iconset"
for size in 16 32 128 256 512; do
  retina=$((size * 2))
  sips -z "$size" "$size" "$library_source" --out "$library_iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$retina" "$retina" "$library_source" --out "$library_iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$resources/LibraryFolder.icns" "$library_iconset"
