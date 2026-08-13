# MacICNS Open Source Presentation Design

## Goal

Turn the GitHub repository into a clear, welcoming open-source project page for an international audience without overstating the current unsigned distribution status.

## README

The English README opens with a centered PNG rendering of the existing MacICNS app icon, project name, one-sentence tagline, and compact badges for macOS 14+, Apple Silicon, latest GitHub Release, and MIT license. A short description explains that MacICNS maps compatible macOS applications to custom `.icns` files, preserves enabled mappings through supported app updates, and reloads the Dock after manual refresh.

Installation remains prominent with DMG, ZIP, and Homebrew sections. The exact first-launch Gatekeeper limitation remains visible: current releases are ad-hoc signed and not notarized, so macOS may require System Settings → Privacy & Security → Open Anyway after the first attempt. The README must not imply that Homebrew bypasses this requirement.

Additional concise sections cover compatibility limits, local-only mapping data/no telemetry, how to contribute, development/test commands, release links, and uninstalling. Tone is practical and direct rather than marketing-heavy.

## Public Assets

Convert the existing tracked `MacICNS/App/AppIcon.icns` into a tracked PNG at `assets/macicns-icon.png`. The README references the repository-relative PNG, so it renders on GitHub without external hosting. The conversion must not replace the app's ICNS source or alter the application bundle.

## Open Source Files

Add an MIT `LICENSE` file copyrighted to Guilherme Abdelnor Tavares, using the current year 2026. Add a concise `CONTRIBUTING.md` with local setup, test command, focused change/commit expectations, and a reminder not to include user mapping data or signing credentials in contributions. Add `CODE_OF_CONDUCT.md` using the Contributor Covenant 2.1 text and a `SECURITY.md` that directs vulnerability reports to GitHub private vulnerability reporting when available, and otherwise asks maintainers to enable it before accepting reports.

Add GitHub issue templates for bug reports and feature requests. Bug reports request macOS version, Mac architecture, MacICNS version, install method, reproducible steps, expected/actual behavior, and sanitized diagnostics. Feature requests request problem, proposed behavior, and alternatives. Neither template asks for credentials or private mapping files.

## Boundaries

- All public-facing project documentation is English.
- No screenshots or GIFs in this iteration; visual assets are limited to the existing app icon rendered as PNG.
- No change to application behavior, release artifacts, Homebrew Cask, signing state, or user mappings.
- Do not claim that protected application icons can be changed or that the app is notarized.

## Verification

- GitHub-relative links and image paths resolve from the README.
- The rendered icon PNG has a supported web format and is non-empty.
- License text is the standard MIT license with the specified copyright holder/year.
- Issue templates and policy files contain no placeholders, secrets, or user-specific local paths.
- README commands match the existing `xcodebuild test` scheme and Homebrew Cask command.
