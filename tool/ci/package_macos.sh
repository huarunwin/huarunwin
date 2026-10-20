#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
[[ ${ASSET_STEM:-} =~ ^HuarunWin-[A-Za-z0-9._-]+$ ]] || {
  echo 'Missing or invalid ASSET_STEM' >&2
  exit 1
}

app=build/macos/Build/Products/Release/HuarunWin.app
output="$PWD/build/release/packages"
mkdir -p "$output"
executable="$app/Contents/MacOS/HuarunWin"
helper="$app/Contents/Helpers/HuarunInstaller"
for binary in "$executable" "$helper"; do
  architectures=" $(xcrun lipo -archs "$binary") "
  [[ $architectures == *' arm64 '* && $architectures == *' x86_64 '* ]] || {
    echo "Missing universal architectures: $binary" >&2
    exit 1
  }
done
/usr/bin/codesign --verify --deep --strict "$app"

stage=$(mktemp -d "$output/dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/HuarunWin.app"
ln -s /Applications "$stage/Applications"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage/HuarunWin.app" "$output/$ASSET_STEM.zip"
/usr/bin/hdiutil create -volname HuarunWin -srcfolder "$stage" -ov -format UDZO "$output/$ASSET_STEM.dmg"
/usr/bin/hdiutil verify "$output/$ASSET_STEM.dmg"
(
  cd "$output"
  test -s "$ASSET_STEM.dmg"
  test -s "$ASSET_STEM.zip"
)
