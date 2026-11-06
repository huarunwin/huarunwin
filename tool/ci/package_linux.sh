#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
[[ ${ASSET_STEM:-} =~ ^HuarunWin-[A-Za-z0-9._-]+$ ]] || {
  echo 'Missing or invalid ASSET_STEM' >&2
  exit 1
}

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) echo 'Linux packages must be built on an amd64 runner' >&2; exit 1 ;;
esac

bundle="$PWD/build/linux/x64/release/bundle"
output="$PWD/build/release/packages"
stage="$PWD/build/release/linux-amd64"
for required in \
  "$bundle/huarunwin" \
  "$bundle/lib/libapp.so" \
  "$bundle/data/icudtl.dat" \
  "$bundle/data/flutter_assets" \
  "$bundle/lib/libflutter_linux_gtk.so"; do
  [[ -e "$required" ]] || { echo "Missing Flutter bundle entry: $required" >&2; exit 1; }
done
[[ -x "$bundle/huarunwin" ]] || { echo 'Linux launcher is not executable' >&2; exit 1; }

rm -rf "$stage"
mkdir -p "$output" "$stage"
cp -a "$bundle/." "$stage/"

package="$output/${ASSET_STEM}-linux-amd64.tar.gz"
rm -f "$package"
tar -czf "$package" -C "$stage" .
tar -tzf "$package" >/dev/null
[[ -s "$package" ]] || { echo 'Empty Linux package' >&2; exit 1; }
echo "Packaged $(basename "$package")"
