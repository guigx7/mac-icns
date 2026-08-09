# Secure Helper Icon Writing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make protected applications such as WhatsApp accept custom icons safely, keep enabled-state presentation consistent, and let users update an already installed helper.

**Architecture:** Replace pathname-based privileged writes with a descriptor-anchored target walk and a narrow Finder metadata writer. Keep all existing XPC identity, request validation, source-file hardening, persistence, and automatic repair boundaries. Expose helper replacement and sanitized failure details through the existing service and app-state layers.

**Tech Stack:** Swift 6, SwiftUI, AppKit, ServiceManagement, Security.framework, Darwin file-descriptor/xattr APIs, XCTest, Xcode build system.

## Global Constraints

- Work only in `/Users/guigx/Projetos/GUIGX/mac-icns/.worktrees/macicns-v1` on `feature/macicns-v1`.
- Use test-driven development for every behavior change: capture the intended failing test, implement the smallest production change, and rerun focused tests.
- Preserve the Team-ID-bound client/helper code-signing requirements and secure-coded XPC request boundary.
- Do not weaken the existing no-follow, regular-file, nonblocking, and 64 MiB limits for source ICNS files.
- Production target validation must require a root-owned, non-group/world-writable, ACL-free final `.app` directory.
- Mutable ancestors may be accepted only because every lookup and write is anchored through directory descriptors.
- Never log file contents or sensitive data. Diagnostic errors may contain only operation, error domain, numeric code, and localized description.
- Make one professional commit per completed task and push after the complete verification task.

## File Structure

- Modify: `Shared/PrivilegedPathValidator.swift` — descriptor-anchored traversal and final-directory policy.
- Create: `Shared/StableApplicationIconWriter.swift` — apply/reset Finder metadata using descriptors.
- Modify: `MacICNSHelper/IconHelperService.swift` — invoke the stable target operation and return useful errors.
- Modify: `MacICNS/Services/HelperInstallationService.swift` — unregister/register update operation.
- Modify: `MacICNS/Services/RepairCoordinator.swift` — retain sanitized operation failure details.
- Modify: `MacICNS/App/AppState.swift` — coordinate helper update, status refresh, and mapping reapply.
- Modify: `MacICNS/UI/SettingsView.swift` — expose `Update Helper` and its progress/failure state.
- Modify: `MacICNSTests/MacICNSTests.swift` — app-state, coordinator, settings presentation, and service tests.
- Create: `MacICNSTests/PrivilegedIconWriterTests.swift` — descriptor traversal and Finder metadata tests.
- Modify: `MacICNS.xcodeproj/project.pbxproj` — add the new shared source and test file to the required targets.

---

### Task 1: Keep Mapping Toggle Presentation Consistent

**Files:**

- Modify: `MacICNS/UI/MappingListView.swift`
- Test: `MacICNSTests/MacICNSTests.swift`

- [x] Add `testMappingToggleLabelReflectsPersistedEnabledState` and confirm it fails because no state-derived toggle presentation exists.
- [x] Hide the visible native toggle label so the row has only one visible status.
- [x] Provide a dynamic accessibility label that returns `Enabled` or `Disabled` from the persisted mapping state.
- [x] Run the focused test and confirm it passes.
- [x] Commit as `930b768 fix: align mapping toggle presentation`.

---

### Task 2: Anchor Privileged Application Validation to Directory Descriptors

**Files:**

- Modify: `Shared/PrivilegedPathValidator.swift`
- Create: `MacICNSTests/PrivilegedIconWriterTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Step 1: Write failing traversal and policy tests**

Add tests covering these contracts:

```swift
func testOpensRootOwnedApplicationBelowGroupWritableApplicationsDirectory() throws
func testRejectsWritableFinalApplicationDirectory() throws
func testRejectsIntermediateSymlink() throws
func testRejectsFinalApplicationSymlink() throws
```

The first test uses an existing root-owned application under `/Applications` when available and skips with a precise reason otherwise. Temporary-fixture tests inject `getuid()` as the required owner so the same production code is exercised without root.

**Step 2: Run the focused suite and capture RED**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -only-testing:MacICNSTests/PrivilegedIconWriterTests -derivedDataPath /private/tmp/macicns-helper-writer-dd
```

Expected: compilation or assertion failure because the descriptor-opening API does not exist and the current ancestor-mode policy rejects `/Applications`.

**Step 3: Implement descriptor traversal**

Add this ownership-transfer API:

```swift
static func openApplicationDirectory(
    applicationURL: URL,
    requiredOwnerUID: uid_t = 0
) throws -> Int32
```

Implementation requirements:

- require an absolute standardized `.app` URL;
- open `/` using `O_RDONLY | O_DIRECTORY | O_CLOEXEC`;
- walk each path component with `openat(previousFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`;
- close the prior descriptor after each successful step and all descriptors on error;
- `fstat` the final descriptor and require a directory owned by `requiredOwnerUID`;
- reject final mode bits `S_IWGRP` or `S_IWOTH`;
- reject an extended ACL on the final directory;
- return the final descriptor to the caller, which must close it;
- preserve `validate(applicationURL:)` as a compatibility wrapper that opens and closes the descriptor.

Do not reject group-writable intermediate directories: the live descriptor chain prevents later pathname redirection.

**Step 4: Make focused tests GREEN**

Run the focused command from Step 2 and confirm every traversal/policy test passes.

**Step 5: Commit**

```bash
git add Shared/PrivilegedPathValidator.swift MacICNSTests/PrivilegedIconWriterTests.swift MacICNS.xcodeproj/project.pbxproj
git commit -m "fix: anchor privileged application paths"
```

---

### Task 3: Write and Restore Finder Icon Metadata Through Stable Descriptors

**Files:**

- Create: `Shared/StableApplicationIconWriter.swift`
- Modify: `MacICNSTests/PrivilegedIconWriterTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Step 1: Add failing metadata tests**

Create a mode-0700 test `.app`, open it through `PrivilegedPathValidator`, and add:

```swift
func testApplyCreatesIconResourceForkAndSetsCustomIconFlag() throws
func testResetRemovesIconAndClearsOnlyCustomIconFlag() throws
func testApplyRejectsSymlinkedIconMetadataFile() throws
```

The reset test first writes an unrelated Finder flag such as `0x2000`; after reset it must still be present while `kHasCustomIcon` (`0x0400`) is absent.

**Step 2: Run focused tests and capture RED**

Use the focused command from Task 2. Expected: compilation failure because `StableApplicationIconWriter` is absent.

**Step 3: Implement the narrow writer**

Expose:

```swift
struct StableApplicationIconWriter {
    func apply(image: NSImage, toApplicationDescriptor descriptor: Int32) throws
    func reset(applicationDescriptor descriptor: Int32) throws
}
```

Apply requirements:

- create a fresh staging directory owned by the helper and force mode `0700`;
- create a staging `.app` directory and ask `NSWorkspace.shared.setIcon` to generate canonical Finder metadata there;
- open staging `Icon\r` without following symlinks;
- read only `com.apple.ResourceFork` and `com.apple.FinderInfo`, bounding every read to 64 MiB;
- open/create target `Icon\r` using `openat(descriptor, ..., O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600)`;
- verify the opened target is a regular file with `fstat`;
- use `fsetxattr` for metadata so no target pathname is re-resolved;
- preserve the target directory's existing FinderInfo bytes and set only bit `0x0400`;
- always close descriptors and remove staging data with `defer`.

Reset requirements:

- remove `Icon\r` relative to the application descriptor using `unlinkat`, treating `ENOENT` as success;
- preserve FinderInfo and clear only bit `0x0400`;
- use `fgetxattr`, `fsetxattr`, and `fremovexattr` on the stable directory descriptor.

**Step 4: Run focused tests and inspect filesystem assertions**

Run the Task 2 focused command. Confirm resource fork presence, flag preservation, reset idempotence, and symlink rejection.

**Step 5: Commit**

```bash
git add Shared/StableApplicationIconWriter.swift MacICNSTests/PrivilegedIconWriterTests.swift MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: write privileged icons through descriptors"
```

---

### Task 4: Integrate the Stable Operation into the Privileged Helper

**Files:**

- Modify: `Shared/StableApplicationIconWriter.swift`
- Modify: `MacICNSHelper/IconHelperService.swift`
- Modify: `MacICNSTests/PrivilegedIconWriterTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Step 1: Add failing operation-level tests**

Add a small `PrivilegedIconOperation` boundary that can inject `requiredOwnerUID` in tests. Cover apply and reset requests against a temporary `.app`, plus final-directory rejection.

```swift
func testPrivilegedOperationAppliesValidatedRequest() throws
func testPrivilegedOperationResetsValidatedRequest() throws
func testPrivilegedOperationRejectsWritableTarget() throws
```

Run the focused writer suite and record RED before adding the operation.

**Step 2: Implement and wire the operation**

The operation must:

- open the app once using `PrivilegedPathValidator.openApplicationDirectory`;
- close the returned descriptor with `defer`;
- load apply image bytes through the existing hardened `IconDataReader`;
- invoke `StableApplicationIconWriter.apply` or `.reset`;
- notify `NSWorkspace` after success so Finder and Dock refresh caches.

Replace the helper's pathname-based `NSWorkspace.shared.setIcon` calls with this operation. Keep listener validation, peer code-signing requirements, secure decoding, and single-reply behavior unchanged.

**Step 3: Verify helper and request suites**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -only-testing:MacICNSTests/PrivilegedIconWriterTests -only-testing:MacICNSTests/IconApplyRequestTests -only-testing:MacICNSTests/IconDataReaderTests -derivedDataPath /private/tmp/macicns-helper-writer-dd
```

Then build:

```bash
xcodebuild build -project MacICNS.xcodeproj -scheme MacICNS -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-helper-writer-dd
```

Expected: focused suites pass and the app bundles the helper without linker or target-membership errors.

**Step 4: Commit**

```bash
git add Shared/StableApplicationIconWriter.swift MacICNSHelper/IconHelperService.swift MacICNSTests/PrivilegedIconWriterTests.swift MacICNS.xcodeproj/project.pbxproj
git commit -m "fix: apply protected icons without pathname races"
```

---

### Task 5: Add Helper Update and Actionable Diagnostics

**Files:**

- Modify: `MacICNS/Services/HelperInstallationService.swift`
- Modify: `MacICNS/Services/RepairCoordinator.swift`
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNS/UI/SettingsView.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`

**Step 1: Add failing service and presentation tests**

Add tests for:

```swift
func testInstalledHelperPresentationOffersUpdate() throws
func testHelperUpdateUnregistersBeforeRegistering() async throws
func testHelperUpdateFailureRemainsVisible() async
func testRepairCoordinatorExposesSanitizedFailureDetails() async
func testSuccessfulHelperUpdateReappliesEnabledMappings() async
```

Make `HelperInstallationService` accept narrow register/unregister/status closures so ordering and errors are deterministic without changing production behavior.

**Step 2: Run focused tests and capture RED**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -only-testing:MacICNSTests/MacICNSTests -derivedDataPath /private/tmp/macicns-helper-writer-dd
```

Expected: tests fail because update and diagnostic-detail APIs are absent.

**Step 3: Implement helper replacement**

- Add `update()` that unregisters the current daemon, waits for completion, registers the embedded daemon, and refreshes status.
- Treat an already-unregistered result as safe to continue; surface all other failures.
- Add an `Update Helper` button when status is installed; disable it and show progress while updating.
- On successful update, have `AppState` refresh helper status and request repair of every enabled mapping.
- Keep initial `Set Up Helper` behavior for not-installed or approval-required states.

**Step 4: Implement sanitized diagnostics**

- Preserve the existing mapping status enum for UI compatibility.
- Store a per-mapping sanitized failure detail after failed apply/reset.
- Log operation, error domain, numeric code, and localized description through the current diagnostics logger.
- Clear stale failure details after success, disable, deletion, or replacement.
- Present concise English guidance distinguishing helper connection, unsafe target, and metadata-write failures.

**Step 5: Run focused tests and commit**

Run the Task 5 focused command and confirm GREEN.

```bash
git add MacICNS/Services/HelperInstallationService.swift MacICNS/Services/RepairCoordinator.swift MacICNS/App/AppState.swift MacICNS/UI/SettingsView.swift MacICNSTests/MacICNSTests.swift
git commit -m "feat: update helper and report icon failures"
```

---

### Task 6: Full Verification, Real WhatsApp Cycle, and Push

**Files:**

- Verify all modified sources, tests, project settings, signatures, and embedded helper layout.

**Step 1: Run static checks**

```bash
git diff --check origin/feature/macicns-v1...HEAD
plutil -lint MacICNS.xcodeproj/project.pbxproj
rg -n 'TODO|FIXME|fatalError\(' MacICNS MacICNSHelper Shared MacICNSTests
```

Review every match; no placeholder or debug-only path may remain in the new implementation.

**Step 2: Run the complete test suite**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-helper-writer-final
```

Expected: `** TEST SUCCEEDED **` with no hangs.

**Step 3: Produce and inspect a signed Debug build**

```bash
xcodebuild build -project MacICNS.xcodeproj -scheme MacICNS -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-helper-writer-final
codesign --verify --deep --strict --verbose=2 /private/tmp/macicns-helper-writer-final/Build/Products/Debug/MacICNS.app
codesign -dv --verbose=4 /private/tmp/macicns-helper-writer-final/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchServices/com.guigx.macicns.helper
plutil -lint /private/tmp/macicns-helper-writer-final/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist
```

Confirm the app and helper identifiers and Team ID match `CodeSigningRequirements.swift`.

**Step 4: Replace the installed helper**

Launch the verified app and click `Update Helper` in Settings. Approve the macOS authorization prompt if shown. Refresh status and confirm the new root helper process is registered.

This is the only step expected to require user action.

**Step 5: Perform a real WhatsApp apply/reset/reapply cycle**

- Select the existing WhatsApp mapping and enable it.
- Confirm the custom icon is applied and the mapping reaches `Up to date` without `Needs permission`.
- Disable it and confirm the original WhatsApp icon returns.
- Re-enable it and confirm the custom icon returns.
- Quit and relaunch MacICNS, then confirm persisted state and automatic repair remain correct.
- Inspect diagnostics to ensure there is no unsafe-path rejection for standard `/Applications` ancestry.

**Step 6: Commit any verification-only corrections separately**

If verification reveals a defect, add a failing regression test, apply the narrow fix, rerun Steps 1–5, and commit using a scoped `fix:` message. Do not squash the professional task commits.

**Step 7: Push**

```bash
git status --short
git log --oneline origin/feature/macicns-v1..HEAD
git push origin feature/macicns-v1
```

Expected: clean worktree and all new commits available on the remote branch.
