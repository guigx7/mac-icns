#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <version> [output-directory]" >&2
  exit 64
fi

version="$1"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must use MAJOR.MINOR.PATCH format." >&2
  exit 64
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
output_directory="${2:-${repository_root}/dist}"
plist_path="${repository_root}/MacICNS/App/Info.plist"
bundle_version="$(plutil -extract CFBundleShortVersionString raw "$plist_path")"
normalized_bundle_version="$bundle_version"
if [[ "$normalized_bundle_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  normalized_bundle_version="${normalized_bundle_version}.0"
fi

if [[ "$normalized_bundle_version" != "$version" ]]; then
  echo "Requested version ${version} does not match CFBundleShortVersionString ${bundle_version}." >&2
  exit 1
fi

mkdir -p "$output_directory"
prefix="MacICNS-v${version}"
zip_path="${output_directory}/${prefix}-macos-arm64.zip"
dmg_path="${output_directory}/${prefix}-macos-arm64.dmg"
checksums_path="${output_directory}/${prefix}-SHA256SUMS.txt"
release_notes_path="${output_directory}/${prefix}-release-notes.md"

for artifact in "$zip_path" "$dmg_path" "$checksums_path" "$release_notes_path"; do
  if [[ -e "$artifact" ]]; then
    echo "Refusing to overwrite existing release artifact: $artifact" >&2
    exit 1
  fi
done

derived_data_directory="$(mktemp -d "/private/tmp/macicns-release-${version}.XXXXXX")"
staging_directory="$(mktemp -d "/private/tmp/macicns-dmg-${version}.XXXXXX")"

cleanup() {
  rm -rf "$derived_data_directory" "$staging_directory"
}
trap cleanup EXIT

xcodebuild build \
  -project "${repository_root}/MacICNS.xcodeproj" \
  -scheme MacICNS \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_directory" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO

app_path="${derived_data_directory}/Build/Products/Release/MacICNS.app"
executable_path="${app_path}/Contents/MacOS/MacICNS"

if [[ ! -d "$app_path" || ! -x "$executable_path" ]]; then
  echo "Release build did not produce MacICNS.app for arm64." >&2
  exit 1
fi

architectures="$(lipo -archs "$executable_path")"
if [[ "$architectures" != "arm64" ]]; then
  echo "Expected arm64-only executable, found: $architectures" >&2
  exit 1
fi

echo "Warning: this release is ad-hoc signed and not notarized." >&2
codesign -dv --verbose=2 "$app_path" >&2 || true

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

ditto "$app_path" "${staging_directory}/MacICNS.app"
ln -s /Applications "${staging_directory}/Applications"
hdiutil create \
  -volname MacICNS \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -fs HFS+ \
  -ov \
  "$dmg_path" >/dev/null

(
  cd "$output_directory"
  shasum -a 256 "$(basename "$zip_path")" "$(basename "$dmg_path")" > "$(basename "$checksums_path")"
)

cat > "$release_notes_path" <<EOF
## MacICNS v${version}

MacICNS applies and maintains custom application icons on Apple-silicon Macs running macOS 14 or later.

### Install

- **Recommended:** download `${prefix}-macos-arm64.dmg`, open it, and drag MacICNS to Applications.
- **ZIP:** download `${prefix}-macos-arm64.zip`, unzip it, and move MacICNS.app to Applications.
- **Homebrew:** `brew install --cask guigx7/tap/macicns`.

### First launch

This build is ad-hoc signed and is **not notarized**. If macOS blocks the first launch, try opening MacICNS once, then go to **System Settings → Privacy & Security** and choose **Open Anyway**. Future launches work normally from Spotlight, Dock, or Applications.

The SHA-256 values for the ZIP and DMG are in `${prefix}-SHA256SUMS.txt`.
EOF

echo "Created release artifacts in $output_directory"
