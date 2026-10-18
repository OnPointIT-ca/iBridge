#!/bin/bash
# Build a personal app bundle. Requires macOS 14+ and Xcode Command Line Tools.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
architecture=$(uname -m)
output=""
usage() { printf '%s\n' 'Usage: build_macos_app.sh [--arch arm64|x86_64|universal] [--output DIRECTORY]'; }
while (($#)); do
  case "$1" in
    --arch|--output)
      (($# >= 2)) || { usage >&2; exit 2; }
      if [[ "$1" == --arch ]]; then architecture=$2; else output=$2; fi
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'Build on macOS 14 or newer.' >&2; exit 1; }
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 14 ]] || { printf '%s\n' 'macOS 14 or newer is required.' >&2; exit 1; }
case "$architecture" in arm64|x86_64|universal) ;; *) usage >&2; exit 2 ;; esac
output=${output:-"$repo/build/macos-$architecture"}
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd)
app="$output/iBridge.app"
[[ ! -e "$app" && ! -L "$app" ]] || { printf 'Output already exists: %s. Choose a new --output directory.\n' "$app" >&2; exit 1; }
stage=$(mktemp -d "$output/.ibridge-build.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/iBridge.app/Contents/MacOS"
cp "$repo/scripts/resources/Info.plist" "$stage/iBridge.app/Contents/Info.plist"
export MACOSX_DEPLOYMENT_TARGET=14.0
build_arch() {
  local arch=$1
  local build_path="$repo/macos/.build/package-$arch"
  xcrun swift build --package-path "$repo/macos" --configuration release --arch "$arch" --build-path "$build_path" >&2
  xcrun swift build --package-path "$repo/macos" --configuration release --arch "$arch" --build-path "$build_path" --show-bin-path
}
if [[ "$architecture" == universal ]]; then
  arm_bin=$(build_arch arm64)
  intel_bin=$(build_arch x86_64)
  xcrun lipo -create "$arm_bin/iBridgeHost" "$intel_bin/iBridgeHost" -output "$stage/iBridge.app/Contents/MacOS/iBridgeHost"
  xcrun lipo -verify_arch arm64 x86_64 "$stage/iBridge.app/Contents/MacOS/iBridgeHost"
  resource_bin=$arm_bin
else
  bin=$(build_arch "$architecture")
  cp "$bin/iBridgeHost" "$stage/iBridge.app/Contents/MacOS/iBridgeHost"
  xcrun lipo -verify_arch "$architecture" "$stage/iBridge.app/Contents/MacOS/iBridgeHost"
  resource_bin=$bin
fi
mkdir -p "$stage/iBridge.app/Contents/Resources"
shopt -s nullglob
resources=("$resource_bin"/*.bundle)
((${#resources[@]})) || { printf '%s\n' 'SwiftPM resource bundle is missing.' >&2; exit 1; }
for resource in "${resources[@]}"; do
  cp -R "$resource" "$stage/iBridge.app/Contents/Resources/"
done
/usr/bin/plutil -lint "$stage/iBridge.app/Contents/Info.plist"
/usr/bin/codesign --force --sign "${IBRIDGE_SIGNING_IDENTITY:--}" --timestamp=none "$stage/iBridge.app"
/usr/bin/codesign --verify --deep --strict "$stage/iBridge.app"
mv "$stage/iBridge.app" "$app"
printf 'Built %s (%s; macOS 14+)\n' "$app" "$architecture"
