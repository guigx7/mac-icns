# MacICNS Release Checklist

Use this checklist for every public MacICNS release. Never replace assets in an existing GitHub Release; make a new patch release instead.

## Version and source

- [ ] Set `CFBundleShortVersionString` to the public semantic version.
- [ ] Increment `CFBundleVersion`.
- [ ] Confirm the intended commit is on `main` and the worktree is clean.

## Validation and artifacts

- [ ] Run the complete XCTest suite with an isolated derived-data path.
- [ ] Run `scripts/release.sh X.Y.Z /private/tmp/macicns-X.Y.Z-artifacts`.
- [ ] Run `scripts/verify-release-artifacts.sh X.Y.Z /private/tmp/macicns-X.Y.Z-artifacts`.
- [ ] Confirm the app executable is `arm64` with `lipo -archs`.
- [ ] Inspect ZIP contents and the mounted DMG's `MacICNS.app` and `Applications` shortcut.
- [ ] Verify `SHA256SUMS.txt` against ZIP and DMG.
- [ ] Confirm generated release notes state macOS 14+, Apple Silicon, and the unsigned/not-notarized first-launch step.

## Publish

- [ ] Push the validated commit to `main`.
- [ ] Create tag `vX.Y.Z` on that exact commit.
- [ ] Create a non-draft GitHub Release without changing an earlier release.
- [ ] Upload the generated ZIP, DMG, and `SHA256SUMS.txt`.
- [ ] Use the generated release notes.

## Homebrew tap

- [ ] Copy the ZIP SHA-256 into `guigx7/homebrew-tap/Casks/macicns.rb`.
- [ ] Update the Cask version and immutable GitHub Release URL.
- [ ] Run `brew audit --cask --new Casks/macicns.rb` in the tap checkout.
- [ ] Test `brew install --cask guigx7/tap/macicns` without overwriting a user's installed MacICNS app unless explicitly approved.
- [ ] Push the updated Cask after the GitHub Release assets are public.

## Future Developer ID release

- [ ] Sign all app code with a valid Developer ID Application certificate.
- [ ] Enable hardened runtime and validate the signature with `codesign --verify --deep --strict --verbose=2`.
- [ ] Submit to Apple notarization, wait for acceptance, and staple the notarization ticket.
- [ ] Re-run first-launch Gatekeeper testing on a clean Mac account.
- [ ] Remove the unsigned distribution warning only after signing, notarization, and fresh-machine validation pass.
