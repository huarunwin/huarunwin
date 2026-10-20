#!/bin/sh
set -eu
helper_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "$helper_dir"
helper_output="$helper_dir/HuarunInstaller"
helper_intermediates="${DERIVED_FILE_DIR}/HuarunInstaller"
mkdir -p "$helper_intermediates"
for helper_arch in $ARCHS; do
  xcrun swiftc -O -target "${helper_arch}-apple-macosx13.0" "${PROJECT_DIR}/Installer/main.swift" "${PROJECT_DIR}/Runner/InstallerProcess.swift" -o "$helper_intermediates/$helper_arch"
done
# Preserve paths containing spaces when passing each architecture to lipo.
set --
for helper_arch in $ARCHS; do set -- "$@" "$helper_intermediates/$helper_arch"; done
xcrun lipo -create "$@" -output "$helper_output"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$helper_output"

# This resource is sealed by the app's subsequent code-signing step. macOS's
# numeric bundle version cannot preserve a prerelease's full identity.
build_version="${FLUTTER_BUILD_NAME}"
build_channel=release
if [ "${CONFIGURATION}" = Debug ]; then build_channel=debug; fi
for build_define in $(printf '%s' "${DART_DEFINES:-}" | tr ',' ' '); do
  decoded_define=$(printf '%s' "$build_define" | /usr/bin/base64 -D)
  case "$decoded_define" in
    HUARUNWIN_VERSION=*) build_version=${decoded_define#HUARUNWIN_VERSION=};;
    HUARUNWIN_UPDATE_CHANNEL=*) build_channel=${decoded_define#HUARUNWIN_UPDATE_CHANNEL=};;
  esac
done
build_resource="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/huarunwin-build.plist"
mkdir -p "$(dirname "$build_resource")"
rm -f "$build_resource"
/usr/bin/plutil -create xml1 "$build_resource"
/usr/bin/plutil -insert version -string "$build_version" "$build_resource"
/usr/bin/plutil -insert channel -string "$build_channel" "$build_resource"
