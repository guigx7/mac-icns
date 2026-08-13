#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <output-directory>" >&2
  exit 64
fi

version="$1"
output_directory="$2"
prefix="MacICNS-v${version}"
zip_path="${output_directory}/${prefix}-macos-arm64.zip"
dmg_path="${output_directory}/${prefix}-macos-arm64.dmg"
checksums_path="${output_directory}/${prefix}-SHA256SUMS.txt"
release_notes_path="${output_directory}/${prefix}-release-notes.md"
mount_directory="$(mktemp -d /private/tmp/macicns-release-verify.XXXXXX)"
attached="false"

cleanup() {
  if [[ "$attached" == "true" ]]; then
    hdiutil detach "$mount_directory" -quiet
  fi
  rmdir "$mount_directory"
}
trap cleanup EXIT

for artifact in "$zip_path" "$dmg_path" "$checksums_path" "$release_notes_path"; do
  if [[ ! -f "$artifact" ]]; then
    echo "Missing release artifact: $artifact" >&2
    exit 1
  fi
done

zip_app_entries="$(unzip -Z1 "$zip_path" | awk -F/ '$1 == "MacICNS.app" { print $1 }' | sort -u)"
if [[ "$zip_app_entries" != "MacICNS.app" ]]; then
  echo "ZIP must contain exactly one top-level MacICNS.app bundle." >&2
  exit 1
fi

hdiutil attach "$dmg_path" -mountpoint "$mount_directory" -nobrowse -quiet
attached="true"

if [[ ! -d "${mount_directory}/MacICNS.app" ]]; then
  echo "DMG is missing MacICNS.app." >&2
  exit 1
fi

if [[ ! -L "${mount_directory}/Applications" ]]; then
  echo "DMG is missing the Applications shortcut." >&2
  exit 1
fi

(
  cd "$output_directory"
  shasum -a 256 -c "$(basename "$checksums_path")"
)
