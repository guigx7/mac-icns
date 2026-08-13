# Open Source Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present MacICNS as a professional English-language open-source project on GitHub with a polished README, app-icon asset, MIT licensing, contributor guidance, security policy, and safe issue templates.

**Architecture:** Repository-only documentation and metadata changes use the existing app ICNS as the source for one rendered PNG asset. The README links solely to tracked repository/release content and preserves factual unsigned-distribution copy; community files separate licensing, contributor process, conduct, security reporting, and issue intake.

**Tech Stack:** Markdown, GitHub issue forms, macOS `iconutil`/`sips`, MIT License, Contributor Covenant 2.1.

## Global Constraints

- All new public-facing prose is English.
- Keep support to Apple Silicon and macOS 14+ only.
- State that current releases are ad-hoc signed and not notarized; never imply Homebrew bypasses Gatekeeper.
- Do not change app source, release assets, Homebrew Cask, signing state, or user mapping data.
- Do not commit user mappings, diagnostics, secrets, signing identities, Apple credentials, or personal file paths.
- No screenshots/GIFs in this iteration; use only the existing app icon as a tracked PNG.

---

### Task 1: Add the README icon asset and license

**Files:**
- Create: `assets/macicns-icon.png`
- Create: `LICENSE`
- Modify: `README.md`
- Test: image metadata, Markdown link/path checks, MIT text checks.

**Interfaces:**
- Consumes: `MacICNS/App/AppIcon.icns` and current release/Homebrew URLs.
- Produces: `assets/macicns-icon.png`, referenced as `assets/macicns-icon.png` from the root README, and a standard MIT `LICENSE`.

- [ ] **Step 1: Verify the current README does not expose a GitHub icon asset or MIT license**

Run:

```bash
test ! -f assets/macicns-icon.png
test ! -f LICENSE
rg -n 'assets/macicns-icon.png|MIT License' README.md
```

Expected: asset and license file checks succeed, and the README search finds no matching presentation elements.

- [ ] **Step 2: Convert the existing ICNS into a web PNG**

Extract `MacICNS/App/AppIcon.icns` with `iconutil --convert iconset` into a temporary directory, select the highest-resolution PNG, and place it at `assets/macicns-icon.png`. Verify it with:

```bash
sips -g pixelWidth -g pixelHeight -g format assets/macicns-icon.png
```

Expected: `png` format with non-zero dimensions. Do not modify the ICNS file.

- [ ] **Step 3: Add the MIT license**

Create `LICENSE` with the standard MIT license, setting the copyright line to:

```text
Copyright (c) 2026 Guilherme Abdelnor Tavares
```

- [ ] **Step 4: Rewrite the README with the public project hierarchy**

Replace `README.md` with an English GitHub-first document containing:

- centered linked `assets/macicns-icon.png`, project name, and tagline;
- badges for macOS 14+, Apple Silicon, latest GitHub Release, and MIT;
- short description of custom icon mappings, automatic supported-update repair, and Dock reload after manual refresh;
- Quick Start with DMG, ZIP, and exact Homebrew command;
- requirements and compatibility limitations for protected/non-writable apps;
- explicit first-launch Gatekeeper recovery via System Settings → Privacy & Security → Open Anyway;
- How It Works, Privacy, Contributing, Development, Uninstall, and License sections;
- links to Releases, `CONTRIBUTING.md`, `SECURITY.md`, and `LICENSE`.

Do not use external image hosting or claim notarization.

- [ ] **Step 5: Verify asset, links, and license content**

Run:

```bash
test -s assets/macicns-icon.png
rg -n 'assets/macicns-icon.png|macOS 14|Apple Silicon|Open Anyway|guigx7/tap/macicns|MIT License|CONTRIBUTING.md|SECURITY.md' README.md
rg -n 'MIT License|Copyright \(c\) 2026 Guilherme Abdelnor Tavares' LICENSE
git diff --check
```

Expected: all required public links/copy are present and the diff is whitespace-clean.

- [ ] **Step 6: Commit the foundation**

```bash
git add README.md LICENSE assets/macicns-icon.png
git commit -m "docs: improve project presentation"
```

### Task 2: Add community and security files

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `CODE_OF_CONDUCT.md`
- Create: `SECURITY.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Test: YAML parsing, content/privacy assertions.

**Interfaces:**
- Consumes: README development command and MacICNS's local-only mapping/privacy boundaries.
- Produces: GitHub-recognized contributor, conduct, security, bug-report, and feature-request entry points.

- [ ] **Step 1: Verify the community entry points are currently absent**

Run:

```bash
test ! -f CONTRIBUTING.md
test ! -f CODE_OF_CONDUCT.md
test ! -f SECURITY.md
test ! -d .github/ISSUE_TEMPLATE
```

Expected: all four checks succeed.

- [ ] **Step 2: Add contributor and security guidance**

Create `CONTRIBUTING.md` in English. Include macOS/Xcode prerequisites, clone/build/test command:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-tests \
  CODE_SIGNING_ALLOWED=NO
```

Require focused, tested changes and conventional concise commits. Explicitly prohibit committing user mappings, diagnostics, credentials, certificates, or private `.icns` files without a license to redistribute.

Create `SECURITY.md` that asks reporters not to open public issues for vulnerabilities, asks maintainers to enable GitHub private vulnerability reporting, and directs non-sensitive bugs to the bug-report template. Do not invent an email address.

- [ ] **Step 3: Add a standard Contributor Covenant 2.1 code of conduct**

Create `CODE_OF_CONDUCT.md` with the unmodified Contributor Covenant 2.1 text and a project-maintainer contact section that refers users to GitHub private reporting or a GitHub issue when private reporting is unavailable. Do not add a personal email address.

- [ ] **Step 4: Add issue forms that avoid sensitive data**

Create `.github/ISSUE_TEMPLATE/bug_report.yml` with required fields for MacICNS version, macOS version, Mac architecture, install method (DMG/ZIP/Homebrew), reproducible steps, expected behavior, actual behavior, and sanitized diagnostics. Include a visible warning not to upload credentials, signing data, personal paths, or mapping files.

Create `.github/ISSUE_TEMPLATE/feature_request.yml` with required fields for the problem, desired behavior, and considered alternatives. Include the same no-sensitive-data warning.

- [ ] **Step 5: Validate policy and form structure**

Run:

```bash
plutil -lint MacICNS/App/Info.plist
ruby -e 'require "yaml"; Dir[".github/ISSUE_TEMPLATE/*.yml"].each { |path| YAML.load_file(path); puts "OK #{path}" }'
rg -n 'mapping|diagnostic|credential|certificate|private|vulnerability' CONTRIBUTING.md SECURITY.md .github/ISSUE_TEMPLATE
rg -n 'Contributor Covenant|2.1' CODE_OF_CONDUCT.md
git diff --check
```

Expected: plist and both YAML forms parse, policies have no personal email or secret, and diff is whitespace-clean.

- [ ] **Step 6: Commit community files**

```bash
git add CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md .github/ISSUE_TEMPLATE
git commit -m "docs: add community guidelines"
```

### Task 3: Validate and publish repository presentation

**Files:**
- Verify: `README.md`, `LICENSE`, `assets/macicns-icon.png`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/*.yml`
- Test: full XCTest suite and static repository checks.

**Interfaces:**
- Consumes: the two presentation commits from Tasks 1–2.
- Produces: a clean `main` branch whose GitHub front page and community settings can consume all new project metadata.

- [ ] **Step 1: Run static release-presentation verification**

Run:

```bash
test -s assets/macicns-icon.png
sips -g format assets/macicns-icon.png
ruby -e 'require "yaml"; Dir[".github/ISSUE_TEMPLATE/*.yml"].each { |path| YAML.load_file(path) }'
git diff --check origin/main...HEAD
```

Expected: PNG metadata reports `png`, both issue forms parse, and no whitespace errors occur.

- [ ] **Step 2: Run the full application suite**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-open-source-presentation-tests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass. The docs-only changes must not access or alter production mappings.

- [ ] **Step 3: Promote the verified commits to main**

Push the current validated branch to `origin/main`, then verify:

```bash
git push origin HEAD:refs/heads/main
git ls-remote origin refs/heads/main
git status --short --branch
```

Expected: remote `main` equals the current validated commit and the worktree is clean.
