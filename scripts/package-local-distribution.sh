#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

channel="$1"
app="${2:A}"
output="${app:h}"
flashraw_input="${3:A}"
case "$channel" in
  app-store-local) bundle_id=io.robinqu.RAWMaster.app-store-local ;;
  website-local) bundle_id=io.robinqu.RAWMaster.website-local ;;
  *) print -u2 'Expected a local distribution channel.'; exit 2 ;;
esac

info="$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$info"
plutil -replace CFBundleDocumentTypes.0.LSHandlerRank -string Alternate "$info"
plutil -insert LSApplicationCategoryType -string public.app-category.photography "$info"
plutil -insert RAWMasterDistributionChannel -string "$channel" "$info"

for binary in "$app/Contents/MacOS/RAWMaster" "$app"/Contents/Frameworks/*.dylib; do
  rpaths=$(otool -l "$binary" | awk '/cmd LC_RPATH$/ { getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }')
  for rpath in "${(@f)rpaths}"; do
    case "$rpath" in
      ''|/usr/lib/swift|@loader_path|@executable_path/../Frameworks) ;;
      *) xcrun install_name_tool -delete_rpath "$rpath" "$binary" ;;
    esac
  done
  if [[ "$binary" != "$app/Contents/MacOS/RAWMaster" ]]; then
    codesign --force --sign - "$binary"
  fi
done

# Seal the host and resources after all nested Mach-O files have their final signatures.
codesign --force --sign - --entitlements scripts/distribution/local-raw.entitlements "$app"
python3 scripts/distribution/verify-local-app.py "$app" "$channel" "$flashraw_input"

if [[ "$channel" == website-local ]]; then
  pkg="$output/RAWMaster Website Local.pkg"
  version=$(plutil -extract CFBundleVersion raw "$info")
  pkgbuild --component "$app" --install-location /Applications --identifier "$bundle_id.installer" --version "$version" "$pkg"
  pkgutil --payload-files "$pkg" > "$output/package-payload.txt"
  (cd "$output" && shasum -a 256 "${pkg:t}") > "$output/package-sha256.txt"
fi
