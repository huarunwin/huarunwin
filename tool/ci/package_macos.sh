#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
[[ ${ASSET_STEM:-} =~ ^HuarunWin-[A-Za-z0-9._-]+$ ]] || {
  echo 'Missing or invalid ASSET_STEM' >&2
  exit 1
}
case "${MACOS_ARCH:-}" in
  arm64) expected_arch=arm64 ;;
  amd64) expected_arch=x86_64 ;;
  *) echo 'MACOS_ARCH must be arm64 or amd64' >&2; exit 1 ;;
esac

app_name=华润赢
app="build/macos/Build/Products/Release/$app_name.app"
output="$PWD/build/release/packages"
mkdir -p "$output"
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
executable="$app/Contents/MacOS/$executable_name"
helper="$app/Contents/Helpers/HuarunInstaller"
for binary in "$executable" "$helper"; do
  architectures="$(xcrun lipo -archs "$binary")"
  [[ $architectures == "$expected_arch" ]] || {
    echo "Expected $expected_arch, found $architectures: $binary" >&2
    exit 1
  }
done
/usr/bin/codesign --verify --deep --strict "$app"

stage=$(mktemp -d "$output/dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/$app_name.app"
ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -volname "$app_name" -srcfolder "$stage" -ov -format UDZO "$output/$ASSET_STEM.dmg"
/usr/bin/hdiutil verify "$output/$ASSET_STEM.dmg"
test -s "$output/$ASSET_STEM.dmg"
