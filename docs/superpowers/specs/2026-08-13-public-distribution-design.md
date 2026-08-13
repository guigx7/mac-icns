# MacICNS Public Distribution Design

## Goal

Make MacICNS available to Apple-silicon macOS 14+ users through GitHub Releases as a ZIP and DMG, and through a dedicated Homebrew Cask tap, without requiring an Apple Developer Program membership during this phase.

## Scope

- Produce `MacICNS-vX.Y.Z-macos-arm64.zip`, containing `MacICNS.app`.
- Produce `MacICNS-vX.Y.Z-macos-arm64.dmg`, presenting `MacICNS.app` and an Applications shortcut.
- Produce a SHA-256 checksum file for both assets.
- Provide a release script that builds the same arm64 Release app for both formats and refuses to publish an ad-hoc artifact as notarized.
- Add a public Homebrew tap repository and a `macicns` Cask that installs the ZIP asset into `/Applications`.
- Document installation, first-launch Gatekeeper behavior, update behavior, uninstalling, and the current unsigned limitation.

## Explicit Constraints

- Supported architecture: Apple Silicon (`arm64`) only.
- Minimum OS: macOS 14.
- The current phase has no Developer ID Application certificate and no Apple notarization.
- Do not create a `.pkg`; MacICNS installs as one application bundle and has no system component.
- Do not overwrite or mutate existing GitHub Release assets. Future packaging changes ship as a new patch release, beginning with `v1.0.1`.
- The distribution system must not read, delete, or modify a user's MacICNS mappings.

## User Experience

GitHub Release pages present the DMG as the recommended download for people. Users open the DMG and drag MacICNS to Applications. The ZIP remains available for manual extraction, automation, and Homebrew.

Because the app is not Developer ID signed or notarized, macOS may block the first launch. The documentation must give the exact recovery path: move the app to Applications, Control-click it in Finder, choose Open, and confirm Open. Once approved, it can be launched normally from Spotlight, Dock, Launchpad, or Login Items.

Homebrew installs the same ZIP asset through a versioned Cask. It must not imply that Homebrew bypasses Gatekeeper: first launch still follows the Finder approval step.

## Release Architecture

`scripts/release.sh` is the single source of artifact generation. It accepts an explicit semantic version such as `1.0.1`, verifies that it matches the app's `CFBundleShortVersionString`, builds an arm64 Release product into a disposable derived-data directory, confirms the output is an app bundle for arm64, packages the bundle as ZIP and DMG, and writes `SHA256SUMS.txt`.

The script creates a staging DMG layout with `MacICNS.app` and an `Applications` symlink. It applies a volume name of `MacICNS`, and produces conventional, versioned asset names. It never edits a GitHub release, pushes a tag, or uploads assets; publication remains an explicit GitHub CLI/Actions step.

The script identifies the signing state using `codesign`. In this phase it prints an unsigned/ad-hoc distribution warning and writes a matching release-note fragment. When a Developer ID becomes available, the same boundary can be extended to require Developer ID validation, notarization, and stapling before assets are published.

## Homebrew Tap

Create the public repository `guigx7/homebrew-tap` with `Casks/macicns.rb`. The Cask references the immutable versioned ZIP URL in the GitHub Release and its SHA-256. It declares `arch arm: "arm64"`, `depends_on macos: ">= :sonoma"`, installs `MacICNS.app`, and documents the unsigned first-launch caveat in `caveats`.

The initial command is:

```bash
brew install --cask guigx7/tap/macicns
```

Each future release updates only the Cask's version and SHA-256 after the GitHub assets are present. The Cask repository has no credentials committed to it.

## Documentation and Release Notes

The README must give the DMG, ZIP, and Homebrew installation paths; require macOS 14+ and Apple Silicon; explain compatibility limits for protected apps; explain Gatekeeper first launch; state no telemetry; show uninstall commands; and link to releases.

Every GitHub Release contains a brief installer note that calls out the unsigned/not-notarized status rather than hiding it. `docs/release-checklist.md` includes the verification sequence for tests, build, architecture, archive contents, checksums, Gatekeeper copy, asset upload, Cask URL/checksum, and future Developer ID/notarization steps.

## Verification

- XCTest suite passes without touching the production mapping repository.
- The release script exits successfully for `1.0.1` and yields exactly one `.app` inside the ZIP plus one `.app` and Applications link inside the DMG.
- `file`/`lipo` confirms an arm64 executable.
- `plutil` confirms version and minimum macOS data in the bundle.
- SHA-256 values match the release assets and Cask source.
- A clean local Homebrew Cask audit passes, and `brew install --cask` is manually testable after the release assets are uploaded.

## Deferred

- Developer ID signing, hardened runtime, notarization, and stapling.
- Intel/universal builds.
- Automatic GitHub Actions publication; the initial release can use the reproducible local script and GitHub CLI.
- Submission to the official `Homebrew/homebrew-cask` repository.
