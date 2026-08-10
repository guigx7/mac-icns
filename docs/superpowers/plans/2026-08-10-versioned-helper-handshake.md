# Versioned Privileged Helper Handshake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure MacICNS reports a privileged helper as installed only when the authenticated running helper matches the protocol expected by the app, and reliably replaces cached build 1 with build 2.

**Architecture:** Add a version handshake to the existing authenticated XPC protocol, then make helper lifecycle state combine `SMAppService` registration with the handshake result. Install and update wait for a matching helper before reapplying icons; stale and unreachable helpers remain actionable non-ready states.

**Tech Stack:** Swift 6, AppKit, SwiftUI, ServiceManagement, NSXPCConnection, XCTest, Xcode build system.

## Global Constraints

- Keep the deployment target at macOS 14.0.
- Keep all user-facing copy in English.
- Continue validating both XPC peers with the existing Team-ID-bound signing requirements.
- Use protocol version `2` and app/helper `CFBundleVersion` `2`.
- Do not attempt writes to apps on the sealed system volume.
- Do not reapply mappings until the expected helper version responds.
- Preserve bounded retries for transient `SMAppServiceErrorDomain` code `1` failures.

---

## File Structure

- `Shared/IconHelperXPCProtocol.swift`: owns the shared protocol-version constant and XPC handshake signature.
- `MacICNSHelper/IconHelperService.swift`: answers authenticated handshake requests.
- `MacICNS/Services/PrivilegedHelperClient.swift`: performs a race-safe asynchronous handshake and existing icon operations.
- `MacICNS/Services/HelperInstallationService.swift`: owns registration and bounded readiness polling.
- `MacICNS/App/AppState.swift`: publishes operational helper status and gates icon reapplication.
- `MacICNS/App/MacICNSApp.swift`: presents installed, stale, unavailable, approval, and absent states.
- `MacICNS/App/Info.plist`: advances the containing app build version.
- `MacICNSHelper/Info.plist`: advances the helper build version.
- `MacICNSTests/IconApplyRequestTests.swift`: verifies the shared protocol contract.
- `MacICNSTests/MacICNSTests.swift`: verifies readiness polling, update behavior, UI presentation, and reapply gating.

### Task 1: Authenticated helper-version handshake

**Files:**
- Modify: `Shared/IconHelperXPCProtocol.swift`
- Modify: `MacICNSHelper/IconHelperService.swift`
- Modify: `MacICNS/Services/PrivilegedHelperClient.swift`
- Test: `MacICNSTests/IconApplyRequestTests.swift`

**Interfaces:**
- Produces: `HelperProtocolVersion.current: Int == 2`.
- Produces: `IconHelperXPCProtocol.protocolVersion(withReply:)`.
- Produces: `PrivilegedHelperClient.protocolVersion() async throws -> Int`.
- Preserves: `applyIcon(_:withReply:)` and `resetIcon(_:withReply:)`.

- [ ] **Step 1: Write the failing protocol-contract test**

Add a test that asserts the hand-authored expected value and calls the new client-facing contract:

```swift
func testPrivilegedHelperProtocolVersionIsTwo() {
    XCTAssertEqual(HelperProtocolVersion.current, 2)
}
```

The production mutation this catches is a client/helper contract version that is not advanced with this incompatible helper behavior.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -only-testing:MacICNSTests/IconApplyRequestTests/testPrivilegedHelperProtocolVersionIsTwo \
  -derivedDataPath /private/tmp/macicns-handshake-red CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `HelperProtocolVersion` does not exist.

- [ ] **Step 3: Add the shared handshake contract**

Implement in `Shared/IconHelperXPCProtocol.swift`:

```swift
enum HelperProtocolVersion {
    static let current = 2
}

@objc protocol IconHelperXPCProtocol {
    func protocolVersion(withReply reply: @escaping (Int) -> Void)
    func applyIcon(_ request: IconApplyRequest, withReply reply: @escaping (NSError?) -> Void)
    func resetIcon(_ request: IconResetRequest, withReply reply: @escaping (NSError?) -> Void)
}
```

Implement the helper reply:

```swift
func protocolVersion(withReply reply: @escaping (Int) -> Void) {
    reply(HelperProtocolVersion.current)
}
```

Implement `PrivilegedHelperClient.protocolVersion() async throws -> Int` using the same privileged connection factory, remote interface, code-signing requirement, interruption handler, invalidation handler, and proxy error handler as icon operations. Generalize the existing locked completion helper to `XPCCompletion<Value>` so exactly one success or failure resumes each continuation and every reply invalidates its connection.

- [ ] **Step 4: Run focused and client-related tests and verify GREEN**

Run the focused test above, then:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -only-testing:MacICNSTests/IconApplyRequestTests \
  -only-testing:MacICNSTests/DirectIconApplierTests \
  -derivedDataPath /private/tmp/macicns-handshake-task1 CODE_SIGNING_ALLOWED=NO
```

Expected: both suites pass and the helper target compiles with the new protocol requirement.

- [ ] **Step 5: Commit the handshake**

```bash
git add Shared/IconHelperXPCProtocol.swift MacICNSHelper/IconHelperService.swift \
  MacICNS/Services/PrivilegedHelperClient.swift MacICNSTests/IconApplyRequestTests.swift
git commit -m "feat: add privileged helper version handshake"
git push origin HEAD:feature/macicns-v1
```

### Task 2: Operational readiness and truthful settings state

**Files:**
- Modify: `MacICNS/Services/HelperInstallationService.swift`
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNS/App/MacICNSApp.swift`
- Test: `MacICNSTests/MacICNSTests.swift`

**Interfaces:**
- Consumes: `HelperProtocolVersion.current` and `PrivilegedHelperClient.protocolVersion()`.
- Produces: `HelperInstallationService.OperationalStatus` with `.notInstalled`, `.installed`, `.requiresApproval`, `.updateRequired`, and `.unavailable`.
- Produces: `HelperInstallationService.operationalStatus() async -> OperationalStatus`.
- Produces: async `installAndWaitUntilReady()` and an updated `update()` that return only after a matching handshake.

- [ ] **Step 1: Write failing readiness and reapply-gating tests**

Add literal-result tests with an injected `versionProvider`:

```swift
@MainActor
func testEnabledRegistrationWithMatchingHandshakeIsInstalled() async {
    let service = HelperInstallationService(
        statusProvider: { .installed },
        register: {}, unregister: {}, openSettings: {},
        versionProvider: { 2 }
    )
    XCTAssertEqual(await service.operationalStatus(), .installed)
}

@MainActor
func testEnabledRegistrationWithOldHandshakeRequiresUpdate() async {
    let service = HelperInstallationService(
        statusProvider: { .installed },
        register: {}, unregister: {}, openSettings: {},
        versionProvider: { 1 }
    )
    XCTAssertEqual(await service.operationalStatus(), .updateRequired)
}

@MainActor
func testEnabledRegistrationWithUnreachableHandshakeIsUnavailable() async {
    let service = HelperInstallationService(
        statusProvider: { .installed },
        register: {}, unregister: {}, openSettings: {},
        versionProvider: { throw NSError(domain: "test.helper", code: 1) }
    )
    XCTAssertEqual(await service.operationalStatus(), .unavailable)
}
```

Add an update test whose version sequence is `[1, 1, 2]`; assert three health checks occur before success. Add a stale-version exhaustion test and assert `UpdateError.helperDidNotBecomeReady`. Add an `AppState` test asserting `RepairCoordinator.repairAll` is not triggered when update exhausts readiness polling.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -only-testing:MacICNSTests/MacICNSTests \
  -derivedDataPath /private/tmp/macicns-readiness-red CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because operational status, version injection, and readiness methods are absent.

- [ ] **Step 3: Implement bounded readiness polling**

Add:

```swift
enum OperationalStatus: Equatable {
    case notInstalled
    case installed
    case requiresApproval
    case updateRequired
    case unavailable
}
```

Inject these dependencies into `HelperInstallationService`:

```swift
private let versionProvider: () async throws -> Int
private let readinessRetryLimit: Int
private let readinessRetryDelay: () async throws -> Void
```

The production initializer uses `PrivilegedHelperClient().protocolVersion()`, a bounded retry count, and a short asynchronous delay. `operationalStatus()` maps registration first; it calls XPC only for `.installed`, returns `.installed` for version `2`, `.updateRequired` for any other version, and `.unavailable` on connection failure.

`installAndWaitUntilReady()` registers and then polls. `update()` keeps unregister/register retries and then polls. A matching handshake returns; stale or unreachable results retry; exhaustion throws `UpdateError.helperDidNotBecomeReady`.

- [ ] **Step 4: Make AppState and Settings use operational status**

Change `AppState.helperStatus` to `HelperInstallationService.OperationalStatus`. Make status refresh and install asynchronous:

```swift
func refreshHelperStatus() async
func installHelper() async
```

On launch and Settings appearance, call them inside `Task`. Only transition into `.installed` after `operationalStatus()` returns `.installed`; only that transition may schedule `.helperUpdated` reapplication. On update/install failure, refresh operational status without erasing the actionable error.

Update settings copy and actions:

- `.installed`: “Helper is installed.” / “Update Helper”
- `.updateRequired`: “Helper update required.” / “Update Helper”
- `.unavailable`: “Helper is registered but unavailable.” / “Update Helper”
- `.notInstalled`: “Helper is not installed.” / “Install Helper”
- `.requiresApproval`: existing approval copy and no primary action

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the focused suite from Step 2 outside the sandbox if macOS denies the test runner connection. Expected: readiness, UI presentation, existing retry, and reapply tests all pass.

- [ ] **Step 6: Commit readiness behavior**

```bash
git add MacICNS/Services/HelperInstallationService.swift MacICNS/App/AppState.swift \
  MacICNS/App/MacICNSApp.swift MacICNSTests/MacICNSTests.swift
git commit -m "fix: verify helper readiness before use"
git push origin HEAD:feature/macicns-v1
```

### Task 3: Advance bundle versions and verify live replacement

**Files:**
- Modify: `MacICNS/App/Info.plist`
- Modify: `MacICNSHelper/Info.plist`
- Verify: signed Debug app and embedded helper in Xcode DerivedData

**Interfaces:**
- Consumes: protocol version `2` and readiness flow from Tasks 1–2.
- Produces: containing app and helper build version `2`, causing Service Management to distinguish the replacement build.

- [ ] **Step 1: Advance both build versions**

Change only `CFBundleVersion` from `1` to `2` in both plist files. Keep `CFBundleShortVersionString` at `1.0`.

- [ ] **Step 2: Verify configuration and run the complete suite**

Run:

```bash
plutil -lint MacICNS/App/Info.plist MacICNSHelper/Info.plist
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-versioned-helper-final CODE_SIGNING_ALLOWED=NO
```

Expected: both plists lint successfully and every test passes.

- [ ] **Step 3: Build and verify the signed app used by Xcode**

Run:

```bash
xcodebuild build -project MacICNS.xcodeproj -scheme MacICNS -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /Users/guigx/Library/Developer/Xcode/DerivedData/MacICNS-eghruyaorilwyqbgvwghyeiedqbp
codesign --verify --deep --strict --verbose=2 \
  /Users/guigx/Library/Developer/Xcode/DerivedData/MacICNS-eghruyaorilwyqbgvwghyeiedqbp/Build/Products/Debug/MacICNS.app
```

Verify with `plutil -p` that both the app Info.plist and processed helper Info.plist report build `2`, and confirm the embedded paths:

```text
MacICNS.app/Contents/Library/LaunchServices/com.guigx.macicns.helper
MacICNS.app/Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist
```

- [ ] **Step 4: Commit and push the version advance**

```bash
git add MacICNS/App/Info.plist MacICNSHelper/Info.plist
git commit -m "chore: advance privileged helper build version"
git push origin HEAD:feature/macicns-v1
```

- [ ] **Step 5: Perform the live helper acceptance test**

Restart MacICNS from the signed DerivedData build. In Settings, run Update Helper once and approve if macOS requests it. Verify:

1. Settings reaches “Helper is installed” only after handshake version `2` responds.
2. `launchctl print system/com.guigx.macicns.helper` reports parent bundle version `2`.
3. Refreshing Amphetamine either applies the icon or records the stable `com.guigx.macicns.helper.icon-write` operation and POSIX error; it must never return the obsolete Swift enum error domain.
4. Find My remains unsupported because `/System` is sealed and read-only.

If Amphetamine returns a stable POSIX error, treat that concrete syscall as a new root-cause input; do not alter helper lifecycle code further.

---

## Final Verification

- [ ] `git diff --check` succeeds.
- [ ] The focused handshake and readiness tests pass.
- [ ] The complete macOS test suite passes.
- [ ] The signed Debug build succeeds and deep code-sign verification passes.
- [ ] The worktree contains only intentional changes and is clean after commits.
- [ ] All commits are pushed to `origin/feature/macicns-v1`.
