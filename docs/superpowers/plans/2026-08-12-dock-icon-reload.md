# Dock Icon Reload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every user-triggered `Refresh Icons` action reapply mappings and reload the Dock so open applications immediately display their refreshed Dock icons.

**Architecture:** Introduce a narrow, injectable `DockReloading` boundary implemented with Foundation's public `Process` API to run the fixed executable `/usr/bin/killall` with the fixed argument `Dock`. `AppState.refreshAll()` remains the single shared action: it completes mapping repair and persistence, then reloads the Dock exactly once. The menu bar and a new main-window toolbar button both call that shared action.

**Tech Stack:** Swift 6, SwiftUI, Foundation `Process`, XCTest, Xcode project file.

## Global Constraints

- All user-facing copy remains in English.
- Use public macOS APIs only.
- Never terminate or relaunch target applications; restarting the Dock process is the explicitly approved feature behavior.
- Do not add a privileged helper or alter mapping JSON compatibility.
- Every test must use a fake `DockReloading`, `MemoryMappingRepository`/`EmptyMappingRepository`, and temporary test fixtures only. Tests must never instantiate the default `JSONMappingRepository()` or touch the user's Application Support `mappings.json`.
- Use TDD and professional commits.

---

## File Structure

- `MacICNS/Services/DockReloader.swift`: owns the public process boundary and its outcome/error mapping.
- `MacICNS/App/AppState.swift`: injects the reloader and calls it once after a completed manual refresh.
- `MacICNS/UI/MappingListView.swift`: adds the main-window toolbar control that invokes the existing AppState refresh action.
- `MacICNS/App/MacICNSApp.swift`: continues using the shared refresh action from the menu bar, adding busy-state disabling.
- `MacICNSTests/DockReloaderTests.swift`: validates command construction through an injectable process-launching seam; never launches `killall` in tests.
- `MacICNSTests/MacICNSTests.swift`: validates AppState ordering, failure isolation, and presentation labels with in-memory repositories/fakes only.
- `MacICNS.xcodeproj/project.pbxproj`: adds the new production and test source files to their respective targets.

---

### Task 1: Add a Safe, Testable Dock Reload Boundary

**Files:**
- Create: `MacICNS/Services/DockReloader.swift`
- Create: `MacICNSTests/DockReloaderTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `protocol DockReloading: Sendable { func reload() async throws }`.
- Produces: `struct DockReloader: DockReloading` with an injectable `DockProcessLaunching` seam.
- Produces: `enum DockReloadError: LocalizedError, Equatable { case nonZeroExit(Int32); case launchFailed }`.

- [ ] **Step 1: Write failing command-construction tests**

Create `MacICNSTests/DockReloaderTests.swift`:

```swift
import XCTest
@testable import MacICNS

final class DockReloaderTests: XCTestCase {
    func testReloadLaunchesOnlyTheFixedDockCommand() async throws {
        let launcher = RecordingDockProcessLauncher(exitStatus: 0)
        let reloader = DockReloader(launcher: launcher)

        try await reloader.reload()

        XCTAssertEqual(await launcher.executableURL, URL(filePath: "/usr/bin/killall"))
        XCTAssertEqual(await launcher.arguments, ["Dock"])
    }

    func testReloadSurfacesANonZeroExitStatus() async {
        let reloader = DockReloader(
            launcher: RecordingDockProcessLauncher(exitStatus: 1)
        )

        do {
            try await reloader.reload()
            XCTFail("Expected reload to fail")
        } catch {
            XCTAssertEqual(error as? DockReloadError, .nonZeroExit(1))
        }
    }
}

private actor RecordingDockProcessLauncher: DockProcessLaunching {
    let exitStatus: Int32
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?

    init(exitStatus: Int32) { self.exitStatus = exitStatus }

    func launch(executableURL: URL, arguments: [String]) async throws -> Int32 {
        self.executableURL = executableURL
        self.arguments = arguments
        return exitStatus
    }
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -quiet CODE_SIGNING_ALLOWED=NO \
  -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-reload \
  -only-testing:MacICNSTests/DockReloaderTests
```

Expected: compilation fails because `DockReloader`, `DockReloading`, and `DockProcessLaunching` are undefined. This command only builds test fixtures and does not invoke `killall` or the user mapping repository.

- [ ] **Step 3: Implement the minimal fixed-command boundary**

Create `MacICNS/Services/DockReloader.swift`:

```swift
import Foundation

protocol DockReloading: Sendable {
    func reload() async throws
}

protocol DockProcessLaunching: Sendable {
    func launch(executableURL: URL, arguments: [String]) async throws -> Int32
}

enum DockReloadError: LocalizedError, Equatable {
    case launchFailed
    case nonZeroExit(Int32)

    var errorDescription: String? {
        switch self {
        case .launchFailed: "Could not reload the Dock."
        case .nonZeroExit: "The Dock did not reload successfully."
        }
    }
}

struct DockReloader: DockReloading {
    private let launcher: any DockProcessLaunching

    init(launcher: any DockProcessLaunching = FoundationDockProcessLauncher()) {
        self.launcher = launcher
    }

    func reload() async throws {
        let status: Int32
        do {
            status = try await launcher.launch(
                executableURL: URL(filePath: "/usr/bin/killall"),
                arguments: ["Dock"]
            )
        } catch {
            throw DockReloadError.launchFailed
        }
        guard status == 0 else { throw DockReloadError.nonZeroExit(status) }
    }
}

struct FoundationDockProcessLauncher: DockProcessLaunching {
    func launch(executableURL: URL, arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
```

- [ ] **Step 4: Register sources in the Xcode project**

Add file/build references using unused IDs:

```text
E10000000000000000000001 /* DockReloader.swift in Sources */
E10000000000000000000002 /* DockReloaderTests.swift in Sources */
E10000000000000000000011 /* DockReloader.swift */
E10000000000000000000012 /* DockReloaderTests.swift */
```

Place `DockReloader.swift` in the `Services` group and production Sources phase; place `DockReloaderTests.swift` in the test group and test Sources phase. Then run:

```bash
plutil -lint MacICNS.xcodeproj/project.pbxproj
```

Expected: `OK`.

- [ ] **Step 5: Run focused tests and commit**

Run the focused command from Step 2. Expected: both tests pass without launching a real process.

```bash
git add MacICNS/Services/DockReloader.swift MacICNSTests/DockReloaderTests.swift MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: add Dock reload boundary"
```

---

### Task 2: Reload the Dock After Shared Manual Refresh

**Files:**
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`

**Interfaces:**
- Consumes: `any DockReloading` from Task 1.
- Changes: `AppState.init(..., dockReloader: any DockReloading = DockReloader())`.
- Produces: `@Published private(set) var isRefreshingAll: Bool` for both controls.
- Changes: public `refreshAll()` reuses existing manual repair behavior then calls the reloader exactly once.

- [ ] **Step 1: Write failing AppState behavior tests using only in-memory state**

Add to `MacICNSTests/MacICNSTests.swift`:

```swift
@MainActor
func testManualRefreshReappliesMappingsThenReloadsDockOnce() async throws {
    let fixture = try MappingFixture()
    defer { fixture.remove() }
    let repository = MemoryMappingRepository([fixture.mapping])
    let applier = LifecycleApplier()
    let reloader = RecordingDockReloader()
    let appState = AppState(
        repository: repository,
        repairCoordinator: RepairCoordinator(applier: applier),
        dockReloader: reloader
    )
    appState.loadMappings()

    await appState.refreshAll()

    XCTAssertEqual(await reloader.reloadCount, 1)
    XCTAssertEqual(repository.savedMappings.count, 1)
}

@MainActor
func testManualRefreshReloadsDockWhenAMappingRepairFails() async throws {
    let fixture = try MappingFixture()
    defer { fixture.remove() }
    let repository = MemoryMappingRepository([fixture.mapping])
    let reloader = RecordingDockReloader()
    let appState = AppState(
        repository: repository,
        repairCoordinator: RepairCoordinator(applier: FailingApplyLifecycleApplier()),
        dockReloader: reloader
    )
    appState.loadMappings()

    await appState.refreshAll()

    XCTAssertEqual(await reloader.reloadCount, 1)
    XCTAssertEqual(repository.savedMappings.first?.status, .failed)
}

@MainActor
func testDockReloadFailurePreservesRefreshResultsAndShowsOperationError() async throws {
    let fixture = try MappingFixture()
    defer { fixture.remove() }
    let repository = MemoryMappingRepository([fixture.mapping])
    let appState = AppState(
        repository: repository,
        repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
        dockReloader: FailingDockReloader()
    )
    appState.loadMappings()

    await appState.refreshAll()

    XCTAssertEqual(repository.savedMappings.first?.status, .upToDate)
    XCTAssertEqual(appState.operationError, "Could not reload the Dock.")
}

private actor RecordingDockReloader: DockReloading {
    private(set) var reloadCount = 0
    func reload() async throws { reloadCount += 1 }
}

private struct FailingDockReloader: DockReloading {
    func reload() async throws { throw DockReloadError.launchFailed }
}

private actor FailingApplyLifecycleApplier: IconApplying {
    func apply(applicationURL: URL, iconURL: URL) async throws {
        throw CocoaError(.fileWriteUnknown)
    }
    func reset(applicationURL: URL) async throws {}
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -quiet CODE_SIGNING_ALLOWED=NO \
  -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-refresh-state \
  -only-testing:MacICNSTests/MacICNSTests/testManualRefreshReappliesMappingsThenReloadsDockOnce \
  -only-testing:MacICNSTests/MacICNSTests/testManualRefreshReloadsDockWhenAMappingRepairFails \
  -only-testing:MacICNSTests/MacICNSTests/testDockReloadFailurePreservesRefreshResultsAndShowsOperationError
```

Expected: compilation fails because AppState has no `dockReloader` dependency. All repositories are in-memory and fixtures remove only their unique temporary directory.

- [ ] **Step 3: Inject and call the reloader after repair persistence**

In `AppState` add:

```swift
@Published private(set) var isRefreshingAll = false
private let dockReloader: any DockReloading
```

Extend its initializer with:

```swift
dockReloader: any DockReloading = DockReloader()
```

and assign `self.dockReloader = dockReloader`.

Replace public `refreshAll()` with:

```swift
func refreshAll() async {
    guard !isRefreshingAll else { return }
    isRefreshingAll = true
    defer { isRefreshingAll = false }
    await refreshAll(reason: .manual, diagnosticMessage: "Manual icon refresh requested.")
    do {
        try await dockReloader.reload()
        recordDiagnostic("Reloaded the Dock after manual icon refresh.")
    } catch {
        operationError = "Could not reload the Dock."
        recordDiagnostic("Could not reload the Dock: \(error.localizedDescription)")
    }
}
```

Do not move the call into private `refreshAll(reason:diagnosticMessage:)`: launch/login/filesystem repairs must not reload the Dock. Keep mapping persistence and failure-detail synchronization intact before the reload attempt.

- [ ] **Step 4: Run focused tests and commit**

Run the focused command from Step 2 and:

```bash
xcodebuild test -quiet CODE_SIGNING_ALLOWED=NO \
  -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-refresh-state \
  -only-testing:MacICNSTests/RepairCoordinatorTests \
  -only-testing:MacICNSTests/MacICNSTests
```

Expected: passing. No test may use `JSONMappingRepository()` without an explicit temporary `fileURL`.

```bash
git add MacICNS/App/AppState.swift MacICNSTests/MacICNSTests.swift
git commit -m "feat: reload Dock after manual refresh"
```

---

### Task 3: Expose the Same Refresh Action in Both Interfaces

**Files:**
- Modify: `MacICNS/App/MacICNSApp.swift`
- Modify: `MacICNS/UI/MappingListView.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`

**Interfaces:**
- Consumes: `AppState.refreshAll()` and `AppState.isRefreshingAll` from Task 2.
- Produces: `MappingListPresentation.refreshIconsLabel == "Refresh Icons"` for deterministic control-copy testing.

- [ ] **Step 1: Write the failing presentation-label test**

Add to `MacICNSTests/MacICNSTests.swift`:

```swift
func testRefreshIconsUsesTheSharedEnglishLabel() {
    XCTAssertEqual(MappingListPresentation.refreshIconsLabel, "Refresh Icons")
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -quiet CODE_SIGNING_ALLOWED=NO \
  -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-refresh-ui \
  -only-testing:MacICNSTests/MacICNSTests/testRefreshIconsUsesTheSharedEnglishLabel
```

Expected: compilation fails because `MappingListPresentation` is undefined. No real mapping repository or Dock process is used.

- [ ] **Step 3: Add the shared-label main-window and menu-bar controls**

Add in `MappingListView.swift`:

```swift
enum MappingListPresentation {
    static let refreshIconsLabel = "Refresh Icons"
}
```

In the existing toolbar, before the Add Mapping button, add:

```swift
Button(MappingListPresentation.refreshIconsLabel, systemImage: "arrow.clockwise") {
    Task { await appState.refreshAll() }
}
.disabled(appState.isRefreshingAll)
```

Replace the menu-bar refresh button in `MacICNSApp.swift` with:

```swift
Button(MappingListPresentation.refreshIconsLabel) {
    Task { await appState.refreshAll() }
}
.disabled(appState.isRefreshingAll)
```

This keeps both surfaces on the same `AppState` operation and blocks duplicate user-triggered refreshes while it is active.

- [ ] **Step 4: Run focused UI test, full suite, and build**

Run:

```bash
xcodebuild test -quiet CODE_SIGNING_ALLOWED=NO \
  -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-refresh-final-test

xcodebuild build -quiet CODE_SIGNING_ALLOWED=NO \
  -project MacICNS.xcodeproj -scheme MacICNS \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-dock-refresh-final-build

plutil -lint MacICNS.xcodeproj/project.pbxproj
git diff --check
git status --short
```

Expected: tests/build exit `0`; project plist lint reports `OK`; diff check is clean; only intentional files are changed. No test launches `killall`, changes `/Applications`, or touches the user's mappings.

- [ ] **Step 5: Commit and push for review**

```bash
git add MacICNS/App/MacICNSApp.swift MacICNS/UI/MappingListView.swift MacICNSTests/MacICNSTests.swift
git commit -m "feat: expose Dock refresh controls"
git push origin HEAD:codex/background-lifecycle
```
