# Public Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship reproducible Apple-silicon ZIP and DMG artifacts for MacICNS, document their unsigned first-launch behavior, and provide an installable Homebrew Cask through `guigx7/homebrew-tap`.

**Architecture:** A shell release script builds the existing Xcode Release target into an isolated derived-data directory and packages that exact `MacICNS.app` as both ZIP and DMG. Release metadata is generated from the app bundle and archive checksums; a separate tap repository Cask consumes the immutable ZIP asset published to GitHub Releases. No installer package, helper, code-signing bypass, or mapping-repository access is introduced.

**Tech Stack:** Xcode/xcodebuild, macOS `ditto`, `hdiutil`, `codesign`, `lipo`, `shasum`, Bash, GitHub Releases, Homebrew Cask Ruby DSL.

## Global Constraints

- Target Apple Silicon only (`arm64`) and macOS 14.0+.
- The first public artifact release is `1.0.1`; never alter existing `v1.0.0` assets.
- Current artifacts are ad-hoc signed/not notarized; all user-facing copy must say this plainly and direct the first launch to System Settings → Privacy & Security → Open Anyway.
- Do not generate a `.pkg`.
- Release/test commands must never access or alter the production mapping repository.
- The release script must build with explicit output paths under `/private/tmp` and must not modify tracked app sources.

---

### Task 1: Create a reproducible artifact builder

**Files:**
- Create: `scripts/release.sh`
- Create: `scripts/verify-release-artifacts.sh`
- Modify: `.gitignore`
- Test: `scripts/verify-release-artifacts.sh`

**Interfaces:**
- Consumes: `MacICNS.xcodeproj`, scheme `MacICNS`, `MacICNS/App/Info.plist`.
- Produces: `dist/MacICNS-v<version>-macos-arm64.zip`, `dist/MacICNS-v<version>-macos-arm64.dmg`, `dist/MacICNS-v<version>-SHA256SUMS.txt`, and `dist/MacICNS-v<version>-release-notes.md`.
- CLI: `scripts/release.sh <version> [output-directory]` and `scripts/verify-release-artifacts.sh <version> <output-directory>`.

- [ ] **Step 1: Write the artifact verification script before the builder**

Create `scripts/verify-release-artifacts.sh` with a strict Bash preamble. Require two arguments, derive the expected ZIP, DMG, checksum file, and release-note file names, and fail when any is absent. Verify the ZIP contains exactly one `MacICNS.app/` top-level bundle, mount the DMG to a temporary mountpoint, verify it contains `MacICNS.app` and an `Applications` symlink, detach it with a trap, and verify the checksum file against both archive files with `shasum -a 256 -c`.

- [ ] **Step 2: Run the verification script against an empty directory**

Run: `scripts/verify-release-artifacts.sh 1.0.1 /private/tmp/macicns-empty-release`

Expected: FAIL with an explicit missing ZIP/DMG artifact message.

- [ ] **Step 3: Implement the release builder**

Create `scripts/release.sh` using `set -euo pipefail`. Validate the requested version as `MAJOR.MINOR.PATCH`; compare it with `CFBundleShortVersionString` from `MacICNS/App/Info.plist` after normalizing `1.0` to `1.0.0`; reject mismatches. Build the Release target for `arch=arm64` with a disposable `/private/tmp/macicns-release-<version>-derived-data` path and `CODE_SIGNING_ALLOWED=NO`. Verify the resulting executable with `lipo -archs` contains only `arm64`, and inspect the bundle signature with `codesign -dv` without treating ad-hoc signing as Developer ID.

Package the same app bundle with:

```bash
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
```

Create a writable DMG staging directory with the app and `Applications` symlink. Use `hdiutil create` to make a compressed read-only `MacICNS` volume. Write both archive hashes to the checksum file. Write release notes which list macOS 14+, Apple Silicon, the Gatekeeper/Open Anyway path, and the absence of Developer ID signing/notarization. Do not call `git`, `gh`, `defaults`, or any MacICNS persistence API.

- [ ] **Step 4: Run the builder to verify it produces artifacts**

Run: `scripts/release.sh 1.0.1 /private/tmp/macicns-1.0.1-artifacts`

Expected: exit 0 and all four versioned output files exist.

- [ ] **Step 5: Run artifact verification**

Run: `scripts/verify-release-artifacts.sh 1.0.1 /private/tmp/macicns-1.0.1-artifacts`

Expected: exit 0; ZIP, mounted DMG, checksum file, and versioned release notes validate.

- [ ] **Step 6: Add generated output exclusions and commit**

Add `dist/` to `.gitignore`. Do not ignore source scripts. Commit:

```bash
git add scripts/release.sh scripts/verify-release-artifacts.sh .gitignore
git commit -m "feat: add release artifact builder"
```

### Task 2: Add distribution documentation and release checklist

**Files:**
- Create: `README.md`
- Create: `docs/release-checklist.md`
- Test: manual copy/link check and `rg` assertions.

**Interfaces:**
- Consumes: asset naming contract from `scripts/release.sh` and install command from `guigx7/homebrew-tap`.
- Produces: user installation and operator release instructions that match actual artifacts.

- [ ] **Step 1: Write doc assertions before content**

Run the following against the currently absent README to prove the required user-facing warnings do not exist:

```bash
rg -n "Apple Silicon|macOS 14|Open Anyway|guigx7/tap/macicns" README.md
```

Expected: FAIL because `README.md` does not exist.

- [ ] **Step 2: Write the README**

Create an English `README.md` containing: a one-sentence product description; macOS 14+ and Apple Silicon requirements; GitHub Release link; DMG installation flow; ZIP installation flow; the precise initial Gatekeeper recovery flow (try opening, then System Settings → Privacy & Security → Open Anyway); Homebrew command `brew install --cask guigx7/tap/macicns`; current protected-app compatibility limit; how manual/automatic icon refresh behaves; data/privacy statement that mappings are local and no telemetry is collected; and uninstall steps that remove only `/Applications/MacICNS.app` and the user mapping data on explicit request.

- [ ] **Step 3: Write the operator checklist**

Create `docs/release-checklist.md` with ordered checkboxes for: bumping `CFBundleShortVersionString`/build number; full XCTest; artifact builder; artifact verifier; inspecting `lipo`, ZIP, DMG, and checksums; creating `vX.Y.Z` on the exact commit; uploading all assets and generated release notes; replacing Cask URL/SHA after assets upload; testing Homebrew installation; and future Developer ID, hardened runtime, notarization, stapling, and Gatekeeper validation. State expressly that no asset is overwritten after publication.

- [ ] **Step 4: Verify documentation contracts**

Run:

```bash
rg -n "Apple Silicon|macOS 14|Open Anyway|guigx7/tap/macicns|notar" README.md docs/release-checklist.md
```

Expected: all distribution constraints and commands are present exactly once in user-facing installation sections.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/release-checklist.md
git commit -m "docs: add distribution instructions"
```

### Task 3: Create and verify the Homebrew tap Cask

**Files:**
- Create outside this repository: `guigx7/homebrew-tap/Casks/macicns.rb`
- Create outside this repository: `guigx7/homebrew-tap/README.md`
- Test: `brew audit --cask --new --tap=guigx7/tap macicns` after the tap is published and installed locally.

**Interfaces:**
- Consumes: the finalized `MacICNS-v1.0.1-macos-arm64.zip` GitHub Release asset URL and SHA-256 from `SHA256SUMS.txt`.
- Produces: a versioned `macicns` Cask installable through `brew install --cask guigx7/tap/macicns`.

- [ ] **Step 1: Create the GitHub tap repository**

Use GitHub CLI to create public repository `guigx7/homebrew-tap` with the current user as owner. Clone it into a disposable `/private/tmp/homebrew-tap` directory. Do not put credentials, Apple IDs, or private keys in this repository.

- [ ] **Step 2: Add the initial failing Cask audit case**

Create `Casks/macicns.rb` with the Cask skeleton and an intentionally absent `sha256` field. Validate the Ruby syntax, then run the Homebrew audit after publishing the tap:

```bash
ruby -c Casks/macicns.rb
brew tap guigx7/tap
brew audit --cask --new --tap=guigx7/tap macicns
```

Expected: FAIL because `sha256` is mandatory for the immutable versioned URL.

- [ ] **Step 3: Implement the Cask with finalized release data**

After uploading the new `v1.0.1` release assets, populate the exact version and ZIP SHA-256. Use this structure:

```ruby
cask "macicns" do
  version "1.0.1"
  sha256 "<zip-sha256>"

  url "https://github.com/guigx7/mac-icns/releases/download/v#{version}/MacICNS-v#{version}-macos-arm64.zip"
  name "MacICNS"
  desc "Apply and maintain custom macOS application icons"
  homepage "https://github.com/guigx7/mac-icns"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MacICNS.app"

  caveats <<~EOS
    MacICNS is not notarized yet. On first launch, open it once, then go to
    System Settings → Privacy & Security and choose Open Anyway if macOS blocks it.
  EOS
end
```

Replace the placeholder only with the locally calculated archive checksum. Keep the URL immutable and versioned.

- [ ] **Step 4: Run Cask audit and installation verification**

Run:

```bash
brew audit --cask --new --tap=guigx7/tap macicns
brew install --cask guigx7/tap/macicns
plutil -extract CFBundleShortVersionString raw /Applications/MacICNS.app/Contents/Info.plist
```

Expected: audit passes and installed version prints `1.0.1`. If MacICNS is already installed, use a disposable test prefix or explicitly ask the user before replacing `/Applications/MacICNS.app`.

- [ ] **Step 5: Commit and push the tap**

```bash
git add Casks/macicns.rb README.md
git commit -m "feat: add MacICNS cask"
git push -u origin main
```

### Task 4: Publish v1.0.1 and reconcile release documentation

**Files:**
- Modify: `MacICNS/App/Info.plist`
- Modify: `README.md` only if generated links need a finalized release URL.
- Test: full XCTest, artifact verification, GitHub Release asset inspection, Cask audit.

**Interfaces:**
- Consumes: versioned artifact contract, release notes, checksum file, and Cask source from Tasks 1–3.
- Produces: public `v1.0.1` GitHub Release containing ZIP, DMG, checksums, and generated release notes; Cask points at that immutable release.

- [ ] **Step 1: Write the version release assertion first**

Before changing the plist, run:

```bash
plutil -extract CFBundleShortVersionString raw MacICNS/App/Info.plist
```

Expected: prints `1.0`, proving the release builder must reject `1.0.1` until the version is bumped.

- [ ] **Step 2: Bump the public version**

Change `CFBundleShortVersionString` to `1.0.1` and increment `CFBundleVersion` from `9` to `10`. Commit:

```bash
git add MacICNS/App/Info.plist
git commit -m "chore: prepare v1.0.1"
```

- [ ] **Step 3: Run full application verification**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-v1.0.1-tests \
  CODE_SIGNING_ALLOWED=NO
scripts/release.sh 1.0.1 /private/tmp/macicns-1.0.1-artifacts
scripts/verify-release-artifacts.sh 1.0.1 /private/tmp/macicns-1.0.1-artifacts
```

Expected: all commands exit 0. No production mapping JSON path is read or written.

- [ ] **Step 4: Push main and create the GitHub Release**

Merge the validated feature branch into `main`, push `main`, then create the immutable tag and release with GitHub CLI:

```bash
gh release create v1.0.1 \
  /private/tmp/macicns-1.0.1-artifacts/MacICNS-v1.0.1-macos-arm64.zip \
  /private/tmp/macicns-1.0.1-artifacts/MacICNS-v1.0.1-macos-arm64.dmg \
  /private/tmp/macicns-1.0.1-artifacts/MacICNS-v1.0.1-SHA256SUMS.txt \
  --target <validated-main-commit> \
  --title 'MacICNS v1.0.1' \
  --notes-file /private/tmp/macicns-1.0.1-artifacts/MacICNS-v1.0.1-release-notes.md
```

Expected: public, non-draft release with all three binary/checksum assets. Do not replace v1.0.0 assets.

- [ ] **Step 5: Verify release and Cask source**

Run:

```bash
gh release view v1.0.1 --repo guigx7/mac-icns --json tagName,isDraft,assets
shasum -a 256 /private/tmp/macicns-1.0.1-artifacts/MacICNS-v1.0.1-macos-arm64.zip
```

Expected: tag is `v1.0.1`, release is not a draft, all ZIP/DMG/checksum assets are uploaded, and the ZIP hash matches `Casks/macicns.rb` exactly.

- [ ] **Step 6: Final commit/push status checks**

Run:

```bash
git status --short --branch
git log origin/main -1 --oneline
```

Expected: clean worktree and remote `main` at the validated release commit.
