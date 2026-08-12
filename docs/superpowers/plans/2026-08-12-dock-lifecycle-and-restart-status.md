# Dock Lifecycle and Restart Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove MacICNS from the Dock when its last real window closes, force manual icon refreshes, and display `Restart required` when a running target app must relaunch before its Dock icon changes.

**Architecture:** A focused AppKit window classifier will exclude menu-bar infrastructure from lifecycle decisions. A shared application-runtime boundary will report whether bundle identifiers are running and publish termination events; `RepairCoordinator` will use it to choose persisted mapping status, while `AppState` reconciles that status after termination. Manual repair reasons will bypass the fingerprint optimization without changing automatic repair behavior.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSApplication`, `NSWorkspace`, `NSRunningApplication`), XCTest, Xcode project files, JSON persistence.

## Global Constraints

- All user-facing copy remains in English.
- Use only public macOS APIs; do not inject into processes, restart Dock, or depend on private window class names.
- Never terminate or relaunch a target application.
- Preserve compatibility with existing `mappings.json` files.
- Do not reintroduce a privileged helper.
- Use TDD for every behavior change and make one professional commit per task.
- Push each completed task commit to `origin/codex/background-lifecycle`.
- The final installed build must replace only `/Applications/MacICNS.app` after a recoverable backup.

## File Structure

- `MacICNS/App/ApplicationLifecycle.swift`: activation-policy controller, delegate bridge, and public-property-based user-facing window classification.
- `MacICNS/Services/ApplicationRuntime.swift`: injectable running-app query and target-termination observation backed by public AppKit APIs.
- `MacICNS/Domain/MappingStatus.swift`: persisted `restartRequired` status.
- `MacICNS/Domain/Repairing.swift`: equatable repair reasons so manual work can be distinguished explicitly.
- `MacICNS/Services/RepairCoordinator.swift`: forced-manual-repair rule and successful-result status selection.
- `MacICNS/App/AppState.swift`: target-termination subscription and restart-status reconciliation.
- `MacICNS/UI/MappingListView.swift`: amber `Restart required` presentation and explanatory copy.
- `MacICNSTests/ApplicationLifecycleTests.swift`: lifecycle/window classification regressions.
- `MacICNSTests/RepairCoordinatorTests.swift`: fingerprint, running-state, success, and failure regressions.
- `MacICNSTests/MacICNSTests.swift`: AppState termination and row-presentation regressions.
- `MacICNSTests/ApplicationRuntimeTests.swift`: notification parsing and running-query boundary tests.
- `MacICNS.xcodeproj/project.pbxproj`: add the new production and test sources.
- `MacICNS/App/Info.plist`: advance the final installed build number from `8` to `9`.

---

### Task 1: Correct User-Facing Window Detection

**Files:**
- Modify: `MacICNS/App/ApplicationLifecycle.swift`
- Modify: `MacICNSTests/ApplicationLifecycleTests.swift`

**Interfaces:**
- Consumes: `[NSWindow]` from `NSApplication.shared.windows`.
- Produces: `ApplicationWindowVisibility.hasVisibleUserFacingWindow(in:) -> Bool` and the existing `MacICNSApplicationDelegate` behavior using it.

- [ ] **Step 1: Write the failing window-classification tests**

Add the following helpers and tests to `ApplicationLifecycleTests`:

```swift
func testStatusLevelWindowDoesNotCountAsUserFacing() {
    let statusWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    statusWindow.level = .statusBar
    statusWindow.orderFront(nil)
    defer { statusWindow.close() }

    XCTAssertFalse(
        ApplicationWindowVisibility.hasVisibleUserFacingWindow(in: [statusWindow])
    )
}

func testVisibleNormalKeyCapableWindowCountsAsUserFacing() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.orderFront(nil)
    defer { window.close() }

    XCTAssertTrue(
        ApplicationWindowVisibility.hasVisibleUserFacingWindow(in: [window])
    )
}

func testHiddenAndMiniaturizedWindowsDoNotCountAsUserFacing() {
    let hidden = NSWindow()
    let miniaturized = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.titled, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    miniaturized.orderFront(nil)
    miniaturized.miniaturize(nil)
    defer { miniaturized.close() }

    XCTAssertFalse(
        ApplicationWindowVisibility.hasVisibleUserFacingWindow(in: [hidden, miniaturized])
    )
}
```

- [ ] **Step 2: Run the focused tests to prove the classifier is missing**

Run:

```bash
xcodebuild test -quiet \
  -project MacICNS.xcodeproj \
  -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-lifecycle \
  -only-testing:MacICNSTests/ApplicationLifecycleTests
```

Expected: FAIL because `ApplicationWindowVisibility` is not defined.

- [ ] **Step 3: Implement the public-property-based classifier**

Add to `ApplicationLifecycle.swift`:

```swift
@MainActor
enum ApplicationWindowVisibility {
    static func hasVisibleUserFacingWindow(in windows: [NSWindow]) -> Bool {
        windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && !(window is NSPanel)
                && window.level == .normal
                && window.canBecomeKey
        }
    }
}
```

Replace the delegate's default `visibleWindowProvider` body with:

```swift
self.visibleWindowProvider = {
    ApplicationWindowVisibility.hasVisibleUserFacingWindow(
        in: NSApplication.shared.windows
    )
}
```

Retain the next-run-loop deferral in `windowWillClose(_:)`.

- [ ] **Step 4: Run focused and full lifecycle verification**

Run the focused command from Step 2, then:

```bash
xcodebuild test -quiet \
  -project MacICNS.xcodeproj \
  -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-lifecycle
```

Expected: PASS, with the status-level regression proving menu-bar windows no longer keep regular activation policy active.

- [ ] **Step 5: Commit and push**

```bash
git add MacICNS/App/ApplicationLifecycle.swift MacICNSTests/ApplicationLifecycleTests.swift
git commit -m "fix: hide Dock icon after closing app windows"
git push
```

---

### Task 2: Add Running-App Status and Forced Manual Repair

**Files:**
- Create: `MacICNS/Services/ApplicationRuntime.swift`
- Modify: `MacICNS/Domain/MappingStatus.swift`
- Modify: `MacICNS/Domain/Repairing.swift`
- Modify: `MacICNS/Services/RepairCoordinator.swift`
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNSTests/RepairCoordinatorTests.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`
- Modify: `MacICNSTests/JSONMappingRepositoryTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `ApplicationRunningChecking.isRunning(bundleIdentifier:) async -> Bool`.
- Produces: `WorkspaceApplicationRuntime.shared` as the production checker and later termination observer.
- Produces: `MappingStatus.restartRequired`.
- Produces: `MappingStatus.isSuccessful` so `upToDate` and `restartRequired` share success control flow.
- Changes: `.manual` repairs always call `IconApplying.apply`; other unchanged repairs remain fingerprint-gated.

- [ ] **Step 1: Write failing forced-refresh and running-status tests**

Change the existing `testRepairSkipsUnchangedMapping` to use `.launch`, and add:

```swift
func testManualRepairAppliesEvenWhenFingerprintsAreUnchanged() async {
    var mapping = makeMapping()
    mapping.appFingerprint = "same"
    mapping.iconFingerprint = "same"
    let applier = RecordingApplier()
    let coordinator = RepairCoordinator(
        fingerprinting: StubFingerprinting(value: "same"),
        applicationRunningChecker: StubRunningChecker(isRunning: false),
        applier: applier
    )

    let repaired = await coordinator.repair(mapping, reason: .manual)

    let requestCount = await applier.requests.count
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(repaired.status, .upToDate)
}

func testSuccessfulRepairOfRunningApplicationRequiresRestart() async {
    let coordinator = RepairCoordinator(
        fingerprinting: StubFingerprinting(value: "new"),
        applicationRunningChecker: StubRunningChecker(isRunning: true),
        applier: RecordingApplier()
    )

    let repaired = await coordinator.repair(makeMapping(), reason: .manual)

    XCTAssertEqual(repaired.status, .restartRequired)
    let failureDetails = await coordinator.failureDetails(for: repaired.id)
    XCTAssertNil(failureDetails)
}

func testSuccessfulRepairWithoutBundleIdentifierIsApplied() async {
    var mapping = makeMapping()
    mapping.bundleIdentifier = nil
    let coordinator = RepairCoordinator(
        fingerprinting: StubFingerprinting(value: "new"),
        applicationRunningChecker: StubRunningChecker(isRunning: true),
        applier: RecordingApplier()
    )

    let repaired = await coordinator.repair(mapping, reason: .manual)

    XCTAssertEqual(repaired.status, .upToDate)
}

func testUnchangedRestartRequiredMappingRemainsPendingWhileTargetRuns() async {
    var mapping = makeMapping()
    mapping.appFingerprint = "same"
    mapping.iconFingerprint = "same"
    mapping.status = .restartRequired
    let coordinator = RepairCoordinator(
        fingerprinting: StubFingerprinting(value: "same"),
        applicationRunningChecker: StubRunningChecker(isRunning: true),
        applier: RecordingApplier()
    )

    let repaired = await coordinator.repair(mapping, reason: .launch)

    XCTAssertEqual(repaired.status, .restartRequired)
}

func testUnchangedRestartRequiredMappingBecomesAppliedAfterTargetStops() async {
    var mapping = makeMapping()
    mapping.appFingerprint = "same"
    mapping.iconFingerprint = "same"
    mapping.status = .restartRequired
    let coordinator = RepairCoordinator(
        fingerprinting: StubFingerprinting(value: "same"),
        applicationRunningChecker: StubRunningChecker(isRunning: false),
        applier: RecordingApplier()
    )

    let repaired = await coordinator.repair(mapping, reason: .launch)

    XCTAssertEqual(repaired.status, .upToDate)
}

func testEnablingRunningApplicationPersistsRestartRequiredSuccess() async {
    var mapping = makeMapping()
    mapping.isEnabled = false
    let coordinator = RepairCoordinator(
        fingerprinting: StubFingerprinting(value: "new"),
        applicationRunningChecker: StubRunningChecker(isRunning: true),
        applier: RecordingApplier()
    )

    let repaired = await coordinator.setEnabled(true, for: mapping)

    XCTAssertTrue(repaired.isEnabled)
    XCTAssertEqual(repaired.status, .restartRequired)
}
```

Add an AppState regression to `MacICNSTests.swift` proving icon replacement accepts the successful pending-restart status:

```swift
@MainActor
func testEnabledIconReplacementPersistsWhenRunningAppRequiresRestart() async throws {
    let fixture = try MappingFixture()
    defer { fixture.remove() }
    var mapping = fixture.mapping
    mapping.bundleIdentifier = "com.example.Target"
    let repository = MemoryMappingRepository([mapping])
    let runningChecker = ConstantRunningChecker(isRunning: true)
    let appState = AppState(
        repository: repository,
        repairCoordinator: RepairCoordinator(
            fingerprinting: ConstantFingerprinting(value: "new"),
            applicationRunningChecker: runningChecker,
            applier: IconReplacementApplier()
        )
    )
    appState.loadMappings()
    try await Task.sleep(for: .milliseconds(50))

    await appState.replaceIcon(for: mapping, with: fixture.replacementIconURL)

    XCTAssertEqual(
        repository.savedMappings.first?.iconURL,
        fixture.replacementIconURL.standardizedFileURL
    )
    XCTAssertEqual(repository.savedMappings.first?.status, .restartRequired)
}

private struct ConstantRunningChecker: ApplicationRunningChecking {
    private let runningValue: Bool

    init(isRunning: Bool) {
        runningValue = isRunning
    }

    func isRunning(bundleIdentifier: String) async -> Bool {
        runningValue
    }
}
```

Add a persistence regression to `JSONMappingRepositoryTests.swift`:

```swift
func testRoundTripPreservesRestartRequiredStatus() throws {
    let url = temporaryDirectory.appending(path: "mappings.json")
    let repository = JSONMappingRepository(fileURL: url)
    var mapping = IconMapping(
        applicationURL: URL(filePath: "/Applications/Test.app"),
        bundleIdentifier: "com.example.Test",
        iconURL: URL(filePath: "/tmp/Test.icns")
    )
    mapping.status = .restartRequired

    try repository.save([mapping])

    XCTAssertEqual(try repository.load().first?.status, .restartRequired)
}
```

Add the test double:

```swift
private struct StubRunningChecker: ApplicationRunningChecking {
    private let runningValue: Bool

    init(isRunning: Bool) {
        runningValue = isRunning
    }

    func isRunning(bundleIdentifier: String) async -> Bool {
        runningValue
    }
}
```

- [ ] **Step 2: Run the focused coordinator tests to prove the new boundary and status are absent**

Run:

```bash
xcodebuild test -quiet \
  -project MacICNS.xcodeproj \
  -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-restart-status \
  -only-testing:MacICNSTests/RepairCoordinatorTests
```

Expected: FAIL for missing `ApplicationRunningChecking`, initializer parameter, and `.restartRequired`.

- [ ] **Step 3: Add the runtime protocols and production running query**

Create `ApplicationRuntime.swift`:

```swift
import AppKit

protocol ApplicationRunningChecking: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
}

@MainActor
protocol ApplicationTerminationObserving: AnyObject {
    func startObservingTerminations(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    )
    func stopObservingTerminations()
}

final class WorkspaceApplicationRuntime: ApplicationRunningChecking, @unchecked Sendable {
    static let shared = WorkspaceApplicationRuntime()

    func isRunning(bundleIdentifier: String) async -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }
}
```

Add these PBX objects and references to `project.pbxproj`:

```text
D10000000000000000000001 /* ApplicationRuntime.swift in Sources */
D10000000000000000000011 /* ApplicationRuntime.swift */
```

Place file reference `D100...011` in the Services group and build file `D100...001` in the MacICNS Sources phase.

- [ ] **Step 4: Add the persisted status and make repair reasons comparable**

Update `MappingStatus.swift`:

```swift
enum MappingStatus: String, Codable, Equatable, Sendable {
    case upToDate
    case restartRequired
    case needsPermission
    case missingApp
    case failed
}

extension MappingStatus {
    var isSuccessful: Bool {
        self == .upToDate || self == .restartRequired
    }
}
```

Update the declaration in `Repairing.swift`:

```swift
enum RepairReason: Equatable, Sendable {
```

- [ ] **Step 5: Implement forced manual repair and result-status selection**

Add to `RepairCoordinator`:

```swift
private let applicationRunningChecker: any ApplicationRunningChecking
```

Extend its initializer:

```swift
init(
    fingerprinting: any Fingerprinting = BundleFingerprinting(),
    locator: any ApplicationLocating = ApplicationLocator(),
    applicationRunningChecker: any ApplicationRunningChecking = WorkspaceApplicationRuntime.shared,
    applier: any IconApplying
) {
    self.fingerprinting = fingerprinting
    self.locator = locator
    self.applicationRunningChecker = applicationRunningChecker
    self.applier = applier
}
```

Replace the unchanged-fingerprint guard with:

```swift
let fingerprintsChanged = appFingerprint != repairedMapping.appFingerprint
    || iconFingerprint != repairedMapping.iconFingerprint

if !fingerprintsChanged, reason != .manual {
    if repairedMapping.status == .restartRequired,
       let bundleIdentifier = repairedMapping.bundleIdentifier {
        repairedMapping.status = await applicationRunningChecker.isRunning(
            bundleIdentifier: bundleIdentifier
        ) ? .restartRequired : .upToDate
    } else {
        repairedMapping.status = .upToDate
    }
    failureDetailsByID[mapping.id] = nil
    return repairedMapping
}
```

After a successful `applier.apply`, set:

```swift
if let bundleIdentifier = repairedMapping.bundleIdentifier,
   await applicationRunningChecker.isRunning(bundleIdentifier: bundleIdentifier) {
    repairedMapping.status = .restartRequired
} else {
    repairedMapping.status = .upToDate
}
```

In `RepairCoordinator.setEnabled`, replace the `.upToDate`-only success guard with:

```swift
guard repaired.status.isSuccessful else {
    var unchanged = mapping
    unchanged.status = repaired.status
    return unchanged
}
```

In `AppState.replaceIcon`, replace its `.upToDate`-only guard with:

```swift
guard repaired.status.isSuccessful else {
    await synchronizeFailureDetails(for: [repaired])
    operationError = mappingFailureMessages[repaired.id]
        ?? "The new icon could not be applied, so the previous mapping was preserved."
    await monitor.start(mappings: mappings)
    recordDiagnostic("Could not replace the icon file for mapping \(candidate.id).")
    return
}
```

Keep failure handling unchanged so failed writes never become `restartRequired`.

- [ ] **Step 6: Run focused and full tests**

Run the focused command from Step 2, then the full suite using the same derived-data path.

Expected: PASS. Verify specifically that automatic unchanged repair makes zero apply requests and manual unchanged repair makes exactly one.

- [ ] **Step 7: Commit and push**

```bash
git add \
  MacICNS/Services/ApplicationRuntime.swift \
  MacICNS/Domain/MappingStatus.swift \
  MacICNS/Domain/Repairing.swift \
  MacICNS/Services/RepairCoordinator.swift \
  MacICNS/App/AppState.swift \
  MacICNSTests/RepairCoordinatorTests.swift \
  MacICNSTests/MacICNSTests.swift \
  MacICNSTests/JSONMappingRepositoryTests.swift \
  MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: mark running apps as requiring restart"
git push
```

---

### Task 3: Reconcile Restart Status After Application Termination

**Files:**
- Modify: `MacICNS/Services/ApplicationRuntime.swift`
- Create: `MacICNSTests/ApplicationRuntimeTests.swift`
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ApplicationRunningChecking.isRunning(bundleIdentifier:)` from Task 2.
- Produces: `ApplicationTerminationObserving.startObservingTerminations(_:)` and `stopObservingTerminations()` implemented by `WorkspaceApplicationRuntime`.
- Produces: `AppState.applicationDidTerminate(bundleIdentifier:) async` for deterministic reconciliation tests.

- [ ] **Step 1: Write failing runtime-notification and AppState reconciliation tests**

Create `ApplicationRuntimeTests.swift` with a production notification parsing test:

```swift
import AppKit
import XCTest
@testable import MacICNS

@MainActor
final class ApplicationRuntimeTests: XCTestCase {
    func testTerminationNotificationYieldsBundleIdentifier() async {
        let center = NotificationCenter()
        let runtime = WorkspaceApplicationRuntime(notificationCenter: center)
        let received = expectation(description: "termination")
        var bundleIdentifier: String?
        runtime.startObservingTerminations { identifier in
            bundleIdentifier = identifier
            received.fulfill()
        }

        center.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: RuntimeApplicationStub(
                bundleIdentifier: "com.example.Target"
            )]
        )

        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(bundleIdentifier, "com.example.Target")
        runtime.stopObservingTerminations()
    }
}

private final class RuntimeApplicationStub: ApplicationIdentity {
    let bundleIdentifier: String?

    init(bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
    }
}
```

The `ApplicationIdentity` protocol introduced in Step 3 allows this test to exercise the production parser without constructing `NSRunningApplication`.

Add AppState tests to `MacICNSTests.swift`:

```swift
@MainActor
func testTargetTerminationClearsRestartRequiredWhenNoProcessRemains() async throws {
    let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
    defer { fixture.remove() }
    var mapping = fixture.mapping
    mapping.status = .restartRequired
    let repository = MemoryMappingRepository([mapping])
    let runningChecker = MutableRunningChecker(values: ["com.example.Target": false])
    let appState = AppState(
        repository: repository,
        repairCoordinator: RepairCoordinator(
            applicationRunningChecker: runningChecker,
            applier: LifecycleApplier()
        ),
        applicationRunningChecker: runningChecker,
        applicationTerminationObserver: NoopTerminationObserver()
    )
    appState.loadMappings()

    await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")

    XCTAssertEqual(appState.mappings.first?.status, .upToDate)
    XCTAssertEqual(repository.savedMappings.first?.status, .upToDate)
}

@MainActor
func testTargetTerminationKeepsRestartRequiredWhileAnotherProcessRuns() async throws {
    let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
    defer { fixture.remove() }
    var mapping = fixture.mapping
    mapping.status = .restartRequired
    let runningChecker = MutableRunningChecker(values: ["com.example.Target": true])
    let appState = AppState(
        repository: MemoryMappingRepository([mapping]),
        repairCoordinator: RepairCoordinator(
            applicationRunningChecker: runningChecker,
            applier: LifecycleApplier()
        ),
        applicationRunningChecker: runningChecker,
        applicationTerminationObserver: NoopTerminationObserver()
    )
    appState.loadMappings()

    await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")

    XCTAssertEqual(appState.mappings.first?.status, .restartRequired)
}

@MainActor
func testUnrelatedTerminationDoesNotChangeRestartRequiredMapping() async throws {
    let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
    defer { fixture.remove() }
    var mapping = fixture.mapping
    mapping.status = .restartRequired
    let appState = AppState(
        repository: MemoryMappingRepository([mapping]),
        repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
        applicationRunningChecker: MutableRunningChecker(values: [:]),
        applicationTerminationObserver: NoopTerminationObserver()
    )
    appState.loadMappings()

    await appState.applicationDidTerminate(bundleIdentifier: "com.example.Other")

    XCTAssertEqual(appState.mappings.first?.status, .restartRequired)
}

@MainActor
func testLaunchingTwiceStartsTerminationObservationOnce() {
    let observer = RecordingTerminationObserver()
    let appState = AppState(
        repository: EmptyMappingRepository(),
        applicationTerminationObserver: observer
    )

    appState.launch()
    appState.launch()

    XCTAssertEqual(observer.startCount, 1)
}
```

- [ ] **Step 2: Run focused tests to verify the observer and reconciliation are missing**

Run:

```bash
xcodebuild test -quiet \
  -project MacICNS.xcodeproj \
  -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-termination \
  -only-testing:MacICNSTests/ApplicationRuntimeTests \
  -only-testing:MacICNSTests/MacICNSTests/testTargetTerminationClearsRestartRequiredWhenNoProcessRemains \
  -only-testing:MacICNSTests/MacICNSTests/testTargetTerminationKeepsRestartRequiredWhileAnotherProcessRuns \
  -only-testing:MacICNSTests/MacICNSTests/testUnrelatedTerminationDoesNotChangeRestartRequiredMapping
```

Expected: FAIL for the missing runtime initializer, identity boundary, AppState dependencies, and reconciliation method.

- [ ] **Step 3: Implement termination observation in the runtime boundary**

Add to `ApplicationRuntime.swift`:

```swift
protocol ApplicationIdentity {
    var bundleIdentifier: String? { get }
}

extension NSRunningApplication: ApplicationIdentity {}

extension WorkspaceApplicationRuntime: ApplicationTerminationObserving {
    @MainActor
    func startObservingTerminations(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        stopObservingTerminations()
        observerToken = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? any ApplicationIdentity,
                  let bundleIdentifier = application.bundleIdentifier else {
                return
            }
            Task { @MainActor in handler(bundleIdentifier) }
        }
    }

    @MainActor
    func stopObservingTerminations() {
        guard let observerToken else { return }
        notificationCenter.removeObserver(observerToken)
        self.observerToken = nil
    }
}
```

Update the class with injected notification center and main-actor token storage:

```swift
private let notificationCenter: NotificationCenter
@MainActor private var observerToken: (any NSObjectProtocol)?

init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
    self.notificationCenter = notificationCenter
}
```

- [ ] **Step 4: Wire observation and deterministic reconciliation into AppState**

Add properties and initializer dependencies:

```swift
private let applicationRunningChecker: any ApplicationRunningChecking
private let applicationTerminationObserver: any ApplicationTerminationObserving

init(
    repository: any MappingRepository = JSONMappingRepository(),
    repairCoordinator: RepairCoordinator = RepairCoordinator(applier: DirectIconApplier()),
    eligibilityPruner: MappingEligibilityPruner = MappingEligibilityPruner(),
    diagnosticLogger: DiagnosticLogger = DiagnosticLogger(),
    applicationRunningChecker: any ApplicationRunningChecking = WorkspaceApplicationRuntime.shared,
    applicationTerminationObserver: any ApplicationTerminationObserving = WorkspaceApplicationRuntime.shared
) {
    self.repository = repository
    self.repairCoordinator = repairCoordinator
    self.eligibilityPruner = eligibilityPruner
    self.diagnosticLogger = diagnosticLogger
    self.applicationRunningChecker = applicationRunningChecker
    self.applicationTerminationObserver = applicationTerminationObserver
}
```

Start the observer in the first successful `launch()` call:

```swift
applicationTerminationObserver.startObservingTerminations { [weak self] bundleIdentifier in
    Task { @MainActor in
        await self?.applicationDidTerminate(bundleIdentifier: bundleIdentifier)
    }
}
```

Add reconciliation:

```swift
func applicationDidTerminate(bundleIdentifier: String) async {
    let matchingIndices = mappings.indices.filter { index in
        mappings[index].isEnabled
            && mappings[index].status == .restartRequired
            && mappings[index].bundleIdentifier == bundleIdentifier
    }
    guard !matchingIndices.isEmpty else {
        return
    }
    let isStillRunning = await applicationRunningChecker.isRunning(
        bundleIdentifier: bundleIdentifier
    )
    guard !isStillRunning else {
        return
    }

    for index in matchingIndices {
        mappings[index].status = .upToDate
    }
    mappingRevision += 1
    saveMappings()
    recordDiagnostic("Application restart completed for \(bundleIdentifier).")
}
```

Change `MappingFixture` to accept an optional identifier:

```swift
init(bundleIdentifier: String? = nil) throws {
    directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let applicationURL = directory.appending(path: "Example.app", directoryHint: .isDirectory)
    let iconURL = directory.appending(path: "Example.icns")
    replacementIconURL = directory.appending(path: "Replacement.icns")
    try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: iconURL)
    try Data("replacement".utf8).write(to: replacementIconURL)
    mapping = IconMapping(
        applicationURL: applicationURL,
        bundleIdentifier: bundleIdentifier,
        iconURL: iconURL
    )
}
```

Add these test doubles:

```swift
private actor MutableRunningChecker: ApplicationRunningChecking {
    private var values: [String: Bool]

    init(values: [String: Bool]) {
        self.values = values
    }

    func isRunning(bundleIdentifier: String) async -> Bool {
        values[bundleIdentifier] ?? false
    }

    func setRunning(_ isRunning: Bool, bundleIdentifier: String) {
        values[bundleIdentifier] = isRunning
    }
}

@MainActor
private final class NoopTerminationObserver: ApplicationTerminationObserving {
    func startObservingTerminations(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {}

    func stopObservingTerminations() {}
}

@MainActor
private final class RecordingTerminationObserver: ApplicationTerminationObserving {
    private(set) var startCount = 0

    func startObservingTerminations(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        startCount += 1
    }

    func stopObservingTerminations() {}
}
```

- [ ] **Step 5: Add the new test source to the Xcode project**

Add these PBX objects and references to the project:

```text
D10000000000000000000002 /* ApplicationRuntimeTests.swift in Sources */
D10000000000000000000012 /* ApplicationRuntimeTests.swift */
```

Place file reference `D100...012` in the MacICNSTests group and build file `D100...002` in the test Sources phase. Run:

```bash
plutil -lint MacICNS.xcodeproj/project.pbxproj
```

Expected: `OK`.

- [ ] **Step 6: Run focused and full tests**

Run the focused command from Step 2 and then the complete test suite.

Expected: PASS. The multiple-process test must retain `restartRequired`, and unrelated notifications must not persist any mapping change.

- [ ] **Step 7: Commit and push**

```bash
git add \
  MacICNS/Services/ApplicationRuntime.swift \
  MacICNS/App/AppState.swift \
  MacICNSTests/ApplicationRuntimeTests.swift \
  MacICNSTests/MacICNSTests.swift \
  MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: reconcile icons after app termination"
git push
```

---

### Task 4: Present Restart Guidance and Install Build 9

**Files:**
- Modify: `MacICNS/UI/MappingListView.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`
- Modify: `MacICNS/App/Info.plist`

**Interfaces:**
- Consumes: `MappingStatus.restartRequired` from Task 2.
- Produces: `MappingRowPresentation.statusName(for:)`, `statusMessage(for:failureMessage:)`, and `isAttentionStatus(_:)` for deterministic UI tests.

- [ ] **Step 1: Write failing presentation tests**

Add to `MacICNSTests.swift`:

```swift
func testRestartRequiredPresentationUsesEnglishGuidance() {
    var mapping = IconMapping(
        applicationURL: URL(filePath: "/Applications/Example.app"),
        bundleIdentifier: "com.example.App",
        iconURL: URL(filePath: "/tmp/Example.icns")
    )
    mapping.status = .restartRequired

    XCTAssertEqual(MappingRowPresentation.statusName(for: mapping), "Restart required")
    XCTAssertEqual(
        MappingRowPresentation.statusMessage(for: mapping, failureMessage: nil),
        "Quit and reopen this app to refresh its Dock icon."
    )
    XCTAssertTrue(MappingRowPresentation.isAttentionStatus(mapping))
}

func testDisabledMappingHidesRestartGuidance() {
    var mapping = IconMapping(
        applicationURL: URL(filePath: "/Applications/Example.app"),
        bundleIdentifier: "com.example.App",
        iconURL: URL(filePath: "/tmp/Example.icns")
    )
    mapping.status = .restartRequired
    mapping.isEnabled = false

    XCTAssertEqual(MappingRowPresentation.statusName(for: mapping), "Disabled")
    XCTAssertNil(MappingRowPresentation.statusMessage(for: mapping, failureMessage: nil))
}
```

- [ ] **Step 2: Run the focused tests to verify the presentation API is absent**

Run:

```bash
xcodebuild test -quiet \
  -project MacICNS.xcodeproj \
  -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-restart-ui \
  -only-testing:MacICNSTests/MacICNSTests/testRestartRequiredPresentationUsesEnglishGuidance \
  -only-testing:MacICNSTests/MacICNSTests/testDisabledMappingHidesRestartGuidance
```

Expected: FAIL because the new presentation functions do not exist.

- [ ] **Step 3: Implement deterministic row presentation**

Expand `MappingRowPresentation`:

```swift
enum MappingRowPresentation {
    static let changeIconLabel = "Change icon"
    static let restartRequiredMessage = "Quit and reopen this app to refresh its Dock icon."

    static func toggleLabel(isEnabled: Bool) -> String {
        isEnabled ? "Enabled" : "Disabled"
    }

    static func statusName(for mapping: IconMapping) -> String {
        mapping.isEnabled ? mapping.status.displayName : "Disabled"
    }

    static func statusMessage(
        for mapping: IconMapping,
        failureMessage: String?
    ) -> String? {
        guard mapping.isEnabled else { return nil }
        return mapping.status == .restartRequired ? restartRequiredMessage : failureMessage
    }

    static func isAttentionStatus(_ mapping: IconMapping) -> Bool {
        mapping.isEnabled
            && (mapping.status == .needsPermission || mapping.status == .restartRequired)
    }
}
```

Update `MappingStatus.displayName` with:

```swift
case .restartRequired: "Restart required"
```

Use the presentation functions in `MappingRowView`; render the returned status message beneath the status, and use `.orange` when `isAttentionStatus(_:)` is true.

- [ ] **Step 4: Run the focused tests and full suite**

Run the focused command from Step 2 and then the full suite.

Expected: PASS, with existing failure messages unchanged for non-restart failures.

- [ ] **Step 5: Commit and push the UI delivery**

```bash
git add MacICNS/UI/MappingListView.swift MacICNSTests/MacICNSTests.swift
git commit -m "feat: explain Dock icon restart requirement"
git push
```

- [ ] **Step 6: Advance the build number and commit**

Change `CFBundleVersion` from `8` to `9` in `MacICNS/App/Info.plist`, then run:

```bash
plutil -lint MacICNS/App/Info.plist
git diff --check
git add MacICNS/App/Info.plist
git commit -m "chore: advance app build for restart status"
git push
```

Expected: plist lint and diff check pass before the commit.

- [ ] **Step 7: Run fresh final verification**

Run:

```bash
xcodebuild test -quiet \
  -project MacICNS.xcodeproj \
  -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-build-9-test

xcodebuild build -quiet \
  -project MacICNS.xcodeproj \
  -scheme MacICNS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-build-9

plutil -lint MacICNS/App/Info.plist MacICNS.xcodeproj/project.pbxproj
git diff --check
git status --short
find /private/tmp/macicns-build-9/Build/Products/Debug/MacICNS.app/Contents \
  -path '*LaunchServices*' -o -path '*LaunchDaemons*' -o -name '*helper*'
plutil -extract CFBundleVersion raw \
  /private/tmp/macicns-build-9/Build/Products/Debug/MacICNS.app/Contents/Info.plist
```

Expected: tests and build exit `0`; plists are `OK`; Git is clean; helper search prints nothing; bundle version prints `9`.

- [ ] **Step 8: Back up and install the verified app**

First obtain a timestamp in its own read-only command and select an explicit unused backup path such as `/private/tmp/MacICNS-build-8-backup-20260812-HHMMSS.app`. Then:

```bash
osascript -e 'tell application id "com.guigx.macicns" to quit'
mv /Applications/MacICNS.app /private/tmp/MacICNS-build-8-backup-20260812-HHMMSS.app
ditto /private/tmp/macicns-build-9/Build/Products/Debug/MacICNS.app /Applications/MacICNS.app
```

Do not reuse the illustrative timestamp literally. If `ditto` fails, restore the exact backup with `mv` before doing anything else.

- [ ] **Step 9: Verify the installation and open it for acceptance**

Run:

```bash
plutil -extract CFBundleVersion raw /Applications/MacICNS.app/Contents/Info.plist
cmp -s \
  /private/tmp/macicns-build-9/Build/Products/Debug/MacICNS.app/Contents/MacOS/MacICNS \
  /Applications/MacICNS.app/Contents/MacOS/MacICNS
find /Applications/MacICNS.app/Contents \
  -path '*LaunchServices*' -o -path '*LaunchDaemons*' -o -name '*helper*'
open /Applications/MacICNS.app
pgrep -fl '/Applications/MacICNS.app/Contents/MacOS/MacICNS'
```

Expected: installed version is `9`; executable comparison exits `0`; helper search is empty; the running process path is `/Applications/MacICNS.app/Contents/MacOS/MacICNS`.

Manual acceptance steps:

1. Close the last MacICNS window and verify MacICNS leaves the Dock but remains in the menu bar.
2. Select `Show MacICNS` and verify the window and Dock presence return.
3. Refresh a mapped application that is currently open and verify the row shows `Restart required` plus the guidance.
4. Quit that target application and verify the row changes to `Applied` without MacICNS restarting it.
5. Reopen the target and verify its Dock icon uses the custom image.
