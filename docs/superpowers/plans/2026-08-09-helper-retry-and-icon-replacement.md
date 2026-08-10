# Reliable Helper Update and Icon Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one-click helper updates survive the observed ServiceManagement race and let users replace an existing mapping's ICNS file directly from its row.

**Architecture:** Replace status-based helper readiness with a bounded, cancellation-aware retry around the registration operation itself, retrying only the observed transient ServiceManagement error. Add a transactional `AppState.replaceIcon` operation that preserves an existing mapping unless an enabled replacement applies successfully, and expose it through a focused row-level ICNS picker.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSOpenPanel`, ServiceManagement `SMAppService`, XCTest, Xcode 17 macOS test runner.

## Global Constraints

- Keep the entire app interface in English.
- Preserve the existing monochrome, compact macOS interface; the broader redesign remains out of scope.
- The app supports macOS 14.0 and later.
- Do not add third-party dependencies.
- Preserve the mapping ID, application URL, bundle identifier, and enabled state when replacing an icon.
- Disabled mappings remain disabled and do not apply the replacement until re-enabled.
- Use TDD and professional, focused commits.

---

### Task 1: Retry Transient Helper Registration

**Files:**
- Modify: `MacICNS/Services/HelperInstallationService.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`

**Interfaces:**
- Consumes: existing `HelperInstallationService.update() async throws` and injected `statusProvider`, `register`, `unregister`, and `openSettings` closures.
- Produces: an extended test initializer with `registrationRetryLimit: Int` and `registrationRetryDelay: () async throws -> Void`; `update()` keeps its existing public signature.

- [ ] **Step 1: Replace the obsolete readiness regression with failing retry tests**

Add tests that make the first two registration attempts throw an `NSError(domain: "SMAppServiceErrorDomain", code: 1)`, then succeed; verify three attempts and two retry delays. Add a second test throwing `HelperUpdateTestError.unregisterFailed` from registration and verify one attempt and zero delays. Add a third test with a retry limit of three and verify `HelperInstallationService.UpdateError.registrationTimedOut`.

```swift
@MainActor
func testHelperUpdateRetriesTransientRegistrationFailure() async throws {
    var attempts = 0
    var delays = 0
    let service = HelperInstallationService(
        statusProvider: { .notInstalled },
        register: {
            attempts += 1
            if attempts < 3 {
                throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
            }
        },
        unregister: {},
        openSettings: {},
        registrationRetryLimit: 4,
        registrationRetryDelay: { delays += 1 }
    )

    try await service.update()

    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(delays, 2)
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -only-testing:MacICNSTests/MacICNSTests/testHelperUpdateRetriesTransientRegistrationFailure -derivedDataPath /private/tmp/macicns-helper-retry-red
```

Expected: compilation fails because the injected retry controls and `registrationTimedOut` do not exist.

- [ ] **Step 3: Implement the bounded retry around registration**

In `HelperInstallationService`, remove `waitUntilRemoved()`. Store the retry limit and delay closure. Production uses 40 attempts with `Task.sleep(for: .milliseconds(250))`, a maximum wait of about ten seconds. The test initializer accepts overrides.

```swift
private func registerAfterRemoval() async throws {
    for attempt in 1...registrationRetryLimit {
        do {
            try registerAction()
            return
        } catch where isTransientRegistrationFailure(error) {
            guard attempt < registrationRetryLimit else {
                throw UpdateError.registrationTimedOut
            }
            try await registrationRetryDelay()
        }
    }
}

private func isTransientRegistrationFailure(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == "SMAppServiceErrorDomain" && error.code == 1
}
```

Call `try await registerAfterRemoval()` after unregistering. Cancellation from the delay propagates immediately. All nonmatching errors propagate without retry.

- [ ] **Step 4: Run focused helper tests and confirm GREEN**

Run all helper-update methods in `MacICNSTests`. Expected: retry success, non-transient propagation, exhaustion, existing update success, and update failure tests pass.

- [ ] **Step 5: Commit the helper fix**

```bash
git add MacICNS/Services/HelperInstallationService.swift MacICNSTests/MacICNSTests.swift
git commit -m "fix: retry transient helper registration"
```

---

### Task 2: Replace a Mapping's ICNS File

**Files:**
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNS/UI/MappingListView.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`

**Interfaces:**
- Consumes: `RepairCoordinator.repair(_:reason:)`, `FileSelectionValidator.lastIconDirectory`, `IconMapping`, and the row's existing busy/error presentation.
- Produces: `AppState.replaceIcon(for:with:) async`; `MappingRowView.changeIcon: () -> Void`; `MappingRowPresentation.changeIconLabel`.

- [ ] **Step 1: Write failing AppState replacement tests**

Add three tests:

1. An enabled mapping with a successful applier persists the new standardized icon URL and records exactly that URL in the applier.
2. An enabled mapping with a failing applier preserves the old icon URL and publishes `operationError`.
3. A disabled mapping persists the new icon URL, remains disabled, and performs zero apply calls.

Use real temporary `.app` and `.icns` fixtures so fingerprinting and file validation exercise production behavior. Extend the test applier to record icon URLs and optionally throw `CocoaError(.fileWriteUnknown)`.

```swift
await appState.replaceIcon(for: mapping, with: replacementIconURL)

XCTAssertEqual(repository.savedMappings.first?.iconURL, replacementIconURL.standardizedFileURL)
XCTAssertEqual(repository.savedMappings.first?.isEnabled, mapping.isEnabled)
```

- [ ] **Step 2: Run the focused replacement tests and confirm RED**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -only-testing:MacICNSTests/MacICNSTests/testEnabledIconReplacementPersistsAfterApply -derivedDataPath /private/tmp/macicns-icon-replacement-red
```

Expected: compilation fails because `AppState.replaceIcon(for:with:)` does not exist.

- [ ] **Step 3: Implement transactional replacement in AppState**

Add `replaceIcon(for:with:) async` with the existing busy-ID guard. Find the current stored mapping by ID to reject stale row values. Build a candidate that changes only `iconURL`, clears `iconFingerprint`, `appFingerprint`, and `lastSuccessAt`, and preserves `isEnabled`.

For a disabled mapping, replace and persist the candidate directly. For an enabled mapping, call `repairCoordinator.repair(candidate, reason: .mappingEdited)` and persist only when `status == .upToDate`; otherwise synchronize candidate failure details, preserve the old stored mapping, and publish the sanitized failure message. Restart monitoring after a successful persisted change.

```swift
func replaceIcon(for mapping: IconMapping, with iconURL: URL) async {
    guard !busyMappingIDs.contains(mapping.id),
          let current = mappings.first(where: { $0.id == mapping.id }) else { return }
    // Create candidate, apply when enabled, commit only on success.
}
```

- [ ] **Step 4: Run focused AppState replacement tests and confirm GREEN**

Expected: all three transactional cases pass and existing toggle/delete tests remain green.

- [ ] **Step 5: Write the failing row presentation test**

Add:

```swift
func testMappingRowExposesChangeIconLabel() {
    XCTAssertEqual(MappingRowPresentation.changeIconLabel, "Change icon")
}
```

Run it and confirm compilation fails because the presentation constant is absent.

- [ ] **Step 6: Add the row action and ICNS picker**

In `MappingListView`, add state for the mapping whose icon is being selected. Pass a `changeIcon` closure to each row. Place a borderless `photo.badge.arrow.down` button immediately to the right of the refresh/helper action and before the toggle, with help text `Change Icon` and accessibility label from `MappingRowPresentation.changeIconLabel`.

Present an `NSOpenPanel` configured with:

```swift
panel.title = "Choose Replacement ICNS File"
panel.prompt = "Choose"
panel.allowedContentTypes = [FileSelectionValidator.icnsType]
panel.directoryURL = FileSelectionValidator.lastIconDirectory
panel.canChooseDirectories = false
panel.canChooseFiles = true
panel.allowsMultipleSelection = false
```

On a valid selection, update `lastIconDirectory` and call `await appState.replaceIcon(for: mapping, with: url)`. Cancellation changes nothing. Keep picker logic in a focused private method and reuse `FileSelectionValidator`.

- [ ] **Step 7: Run row and replacement tests and confirm GREEN**

Run the focused `MacICNSTests` methods. Expected: presentation and all replacement behavior pass.

- [ ] **Step 8: Commit the mapping feature**

```bash
git add MacICNS/App/AppState.swift MacICNS/UI/MappingListView.swift MacICNSTests/MacICNSTests.swift
git commit -m "feat: replace mapped icons in place"
```

---

### Task 3: Full Verification and Runtime Build

**Files:**
- Verify only; no planned source changes.

**Interfaces:**
- Consumes: completed helper retry and mapping replacement behavior.
- Produces: a signed Debug application ready for the real helper update and WhatsApp icon test.

- [ ] **Step 1: Run the complete test suite from fresh DerivedData**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-final-verification
```

Expected: `** TEST SUCCEEDED **` with zero failing tests.

- [ ] **Step 2: Build a fresh signed Debug application**

```bash
xcodebuild build -project MacICNS.xcodeproj -scheme MacICNS -destination 'platform=macOS' -configuration Debug -derivedDataPath /private/tmp/macicns-final-runtime
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify bundle and helper signatures**

```bash
codesign --verify --deep --strict --verbose=2 /private/tmp/macicns-final-runtime/Build/Products/Debug/MacICNS.app
codesign -dvvv /private/tmp/macicns-final-runtime/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchServices/com.guigx.macicns.helper
```

Expected: the app satisfies its designated requirement and the helper reports identifier `com.guigx.macicns.helper` with TeamIdentifier `DHAFYHA4FG`.

- [ ] **Step 4: Push both implementation commits**

```bash
git push origin feature/macicns-v1
```

- [ ] **Step 5: Open the verified build for the user test**

Close older MacICNS instances, open `/private/tmp/macicns-final-runtime/Build/Products/Debug/MacICNS.app`, and ask the user to verify Update Helper followed by replacing the WhatsApp icon through the new row button.
