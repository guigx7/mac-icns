# MacICNS

MacICNS is a lightweight macOS menu-bar app for applying custom `.icns` files to compatible applications and keeping those icons current after app updates.

## Requirements

- Apple Silicon Mac (M-series)
- macOS 14 Sonoma or later

MacICNS intentionally excludes applications whose icons cannot be safely changed on the current Mac. System-protected, App Store-managed, or otherwise non-writable applications may not be available in the app picker.

## Install

### DMG (recommended)

1. Download the latest `MacICNS-vX.Y.Z-macos-arm64.dmg` from [Releases](https://github.com/guigx7/mac-icns/releases).
2. Open the disk image.
3. Drag **MacICNS.app** to **Applications**.

### ZIP

1. Download `MacICNS-vX.Y.Z-macos-arm64.zip` from [Releases](https://github.com/guigx7/mac-icns/releases).
2. Unzip it and move **MacICNS.app** to `/Applications`.

### Homebrew

```bash
brew install --cask guigx7/tap/macicns
```

Homebrew installs the same ZIP distribution into Applications.

## First launch security notice

Current releases are ad-hoc signed and are **not notarized by Apple**. macOS may block the first launch of a downloaded copy. If it does:

1. Try to open MacICNS once.
2. Open **System Settings → Privacy & Security**.
3. Scroll to Security and choose **Open Anyway** for MacICNS.
4. Confirm **Open**.

The app is then saved as an exception, and later launches work normally from Spotlight, Dock, Launchpad, or Applications.

## Using MacICNS

Choose a compatible application and an `.icns` file to create a mapping. Turn a mapping off to restore the app's default icon, change its icon without recreating the mapping, or remove the mapping entirely. MacICNS watches enabled mappings and reapplies them after supported app updates. Use **Refresh Icons** from the menu bar or main window to reapply mappings and reload the Dock icon cache.

## Privacy

MacICNS stores your icon mappings locally on your Mac. It does not collect telemetry, create online accounts, or send mapping data anywhere.

## Uninstall

1. Quit MacICNS from its menu-bar menu.
2. Delete `/Applications/MacICNS.app`.
3. To also remove local mappings and diagnostics, delete `~/Library/Application Support/MacICNS/` only if you no longer need them. This is optional and cannot be undone.

## Checksums

Each release includes `MacICNS-vX.Y.Z-SHA256SUMS.txt` for verifying the ZIP and DMG downloads.
