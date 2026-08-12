# Background Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep MacICNS running from the menu bar after its last window closes, dynamically hide it from the Dock, restore regular Dock presence before reopening a window, and install the verified build in `/Applications`.

**Architecture:** A focused `ApplicationLifecycleController` owns activation-policy decisions behind an injectable closure. A small `NSApplicationDelegate` bridge translates AppKit window notifications into controller inputs, while SwiftUI explicitly restores regular mode before opening the management window.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Xcode 26, macOS 14+

## Global Constraints

- The process must remain alive after its last window closes.
- The app must use `.regular` activation policy while a MacICNS window is visible.
- The app must use `.accessory` activation policy while no MacICNS window is visible.
- `LSUIElement` must not be added because the Dock behavior is dynamic.
- Menu bar actions `Show MacICNS`, `Refresh Icons`, and `Quit` must remain available.
- Only `/Applications/MacICNS.app` may be replaced during installation.
- The built and installed app must contain no privileged helper executable or daemon plist.
- All interface copy remains in English.

---

### Task 1: Activation Policy Controller

**Files:**
- Create: `MacICNS/App/ApplicationLifecycle.swift`
- Create: `MacICNSTests/ApplicationLifecycleTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `NSApplication.ActivationPolicy`
- Produces: `@MainActor final class ApplicationLifecycleController`
- Produces: `func showApplication()`
- Produces: `func windowsDidChange(hasVisibleWindows: Bool)`

- [ ] **Step 1: Add the controller tests and Xcode test-file references**

```swift
import AppKit
import XCTest
@testable import MacICNS

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    func testShowApplicationRequestsRegularActivationPolicy() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = ApplicationLifecycleController { policy in
            policies.append(policy)
            return true
        }

        controller.showApplication()

        XCTAssertEqual(policies, [.regular])
    }

    func testClosingLastVisibleWindowRequestsAccessoryActivationPolicy() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = ApplicationLifecycleController { policy in
            policies.append(policy)
            return true
        }

        controller.windowsDidChange(hasVisibleWindows: false)

        XCTAssertEqual(policies, [.accessory])
    }

    func testRemainingVisibleWindowKeepsRegularActivationPolicy() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = ApplicationLifecycleController { policy in
            policies.append(policy)
            return true
        }

        controller.windowsDidChange(hasVisibleWindows: true)

        XCTAssertEqual(policies, [.regular])
    }

    func testReopeningAfterBackgroundingRequestsRegularPolicyLast() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = ApplicationLifecycleController { policy in
            policies.append(policy)
            return true
        }

        controller.windowsDidChange(hasVisibleWindows: false)
        controller.showApplication()

        XCTAssertEqual(policies, [.accessory, .regular])
    }
}
```

Add `ApplicationLifecycleTests.swift` to the `MacICNSTests` group and test Sources phase. Add `ApplicationLifecycle.swift` to the app group and app Sources phase.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-lifecycle-derived \
  -only-testing:MacICNSTests/ApplicationLifecycleTests
```

Expected: compilation fails because `ApplicationLifecycleController` does not exist.

- [ ] **Step 3: Implement the minimal controller**

```swift
import AppKit

@MainActor
final class ApplicationLifecycleController {
    typealias SetActivationPolicy = (NSApplication.ActivationPolicy) -> Bool

    private let setActivationPolicy: SetActivationPolicy

    init(
        setActivationPolicy: @escaping SetActivationPolicy = {
            NSApplication.shared.setActivationPolicy($0)
        }
    ) {
        self.setActivationPolicy = setActivationPolicy
    }

    func showApplication() {
        setActivationPolicy(.regular)
    }

    func windowsDidChange(hasVisibleWindows: Bool) {
        setActivationPolicy(hasVisibleWindows ? .regular : .accessory)
    }
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the focused command from Step 2.

Expected: all four `ApplicationLifecycleTests` pass.

- [ ] **Step 5: Commit the controller**

```bash
git add MacICNS/App/ApplicationLifecycle.swift \
  MacICNSTests/ApplicationLifecycleTests.swift \
  MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: add dynamic activation policy controller"
```

---

### Task 2: AppKit Window Lifecycle Bridge

**Files:**
- Modify: `MacICNS/App/ApplicationLifecycle.swift`
- Modify: `MacICNS/App/MacICNSApp.swift`
- Modify: `MacICNSTests/ApplicationLifecycleTests.swift`

**Interfaces:**
- Consumes: `ApplicationLifecycleController.showApplication()`
- Consumes: `ApplicationLifecycleController.windowsDidChange(hasVisibleWindows:)`
- Produces: `@MainActor final class MacICNSApplicationDelegate: NSObject, NSApplicationDelegate`
- Produces: `func applicationShouldTerminateAfterLastWindowClosed(_:) -> Bool`

- [ ] **Step 1: Add a failing test for last-window termination behavior**

```swift
func testApplicationDelegateKeepsProcessAliveAfterLastWindowCloses() {
    let applicationDelegate = MacICNSApplicationDelegate(
        lifecycleController: ApplicationLifecycleController { _ in true },
        visibleWindowProvider: { false }
    )

    XCTAssertFalse(
        applicationDelegate.applicationShouldTerminateAfterLastWindowClosed(.shared)
    )
}
```

The production change caught by this test is an app delegate that allows AppKit to terminate MacICNS after its last window closes.

- [ ] **Step 2: Run the focused suite and verify RED**

Run the focused command from Task 1.

Expected: compilation fails because `MacICNSApplicationDelegate` does not exist.

- [ ] **Step 3: Implement the AppKit bridge**

Append to `ApplicationLifecycle.swift`:

```swift
@MainActor
final class MacICNSApplicationDelegate: NSObject, NSApplicationDelegate {
    let lifecycleController: ApplicationLifecycleController
    private let visibleWindowProvider: () -> Bool

    init(
        lifecycleController: ApplicationLifecycleController = ApplicationLifecycleController(),
        visibleWindowProvider: @escaping () -> Bool = {
            NSApplication.shared.windows.contains { window in
                window.isVisible && !window.isMiniaturized && !(window is NSPanel)
            }
        }
    ) {
        self.lifecycleController = lifecycleController
        self.visibleWindowProvider = visibleWindowProvider
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didDeminiaturizeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        synchronizeWindowVisibility()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.synchronizeWindowVisibility()
        }
    }

    private func synchronizeWindowVisibility() {
        lifecycleController.windowsDidChange(
            hasVisibleWindows: visibleWindowProvider()
        )
    }
}
```

- [ ] **Step 4: Connect the delegate to SwiftUI and restore regular mode before opening**

In `MacICNSApp` add:

```swift
@NSApplicationDelegateAdaptor(MacICNSApplicationDelegate.self)
private var applicationDelegate
```

Change `focusMainWindow()` to:

```swift
private func focusMainWindow() {
    applicationDelegate.lifecycleController.showApplication()
    openWindow(id: Self.managementWindowID)
    NSApplication.shared.activate(ignoringOtherApps: true)
}
```

Do not add `LSUIElement` to `Info.plist`. Keep `Quit` as the explicit termination action.

- [ ] **Step 5: Run lifecycle tests, then the full suite**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-lifecycle-derived \
  -only-testing:MacICNSTests/ApplicationLifecycleTests
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-lifecycle-derived
```

Expected: focused and full suites report `TEST SUCCEEDED`.

- [ ] **Step 6: Commit the lifecycle integration**

```bash
git add MacICNS/App/ApplicationLifecycle.swift \
  MacICNS/App/MacICNSApp.swift \
  MacICNSTests/ApplicationLifecycleTests.swift
git commit -m "feat: keep app active after closing windows"
```

---

### Task 3: Build Number, Bundle Verification, and Installation

**Files:**
- Modify: `MacICNS/App/Info.plist`

**Interfaces:**
- Consumes: verified Debug product at `/private/tmp/macicns-install-derived/Build/Products/Debug/MacICNS.app`
- Produces: installed application at `/Applications/MacICNS.app`

- [ ] **Step 1: Advance the build number**

Change:

```xml
<key>CFBundleVersion</key><string>8</string>
```

Keep `CFBundleShortVersionString` at `1.0`.

- [ ] **Step 2: Run clean full verification**

Run:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-install-derived
xcodebuild build -project MacICNS.xcodeproj -scheme MacICNS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-install-derived
plutil -lint MacICNS.xcodeproj/project.pbxproj MacICNS/App/Info.plist
git diff --check
codesign --verify --deep --strict --verbose=4 \
  /private/tmp/macicns-install-derived/Build/Products/Debug/MacICNS.app
test ! -e /private/tmp/macicns-install-derived/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchServices/com.guigx.macicns.helper
test ! -e /private/tmp/macicns-install-derived/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist
```

Expected: tests/build succeed; plist, signature, diff, and helper-absence checks exit zero.

- [ ] **Step 3: Commit and push the verified source**

```bash
git add MacICNS/App/Info.plist
git commit -m "chore: advance app build for installation"
git push -u origin codex/background-lifecycle
```

- [ ] **Step 4: Replace only the installed MacICNS bundle**

First request elevated approval because `/Applications` is outside the workspace and stop the currently running MacICNS process. Preserve the old bundle as a scoped backup before copying:

```bash
osascript -e 'tell application id "com.guigx.macicns" to quit' || true
mv /Applications/MacICNS.app /private/tmp/MacICNS-build-6-backup.app
ditto /private/tmp/macicns-install-derived/Build/Products/Debug/MacICNS.app \
  /Applications/MacICNS.app
```

If the exact backup path already exists, use `/private/tmp/MacICNS-build-6-backup-<timestamp>.app`. Never remove or overwrite another backup.

- [ ] **Step 5: Verify and launch the installed application**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  /Applications/MacICNS.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=4 /Applications/MacICNS.app
test ! -e /Applications/MacICNS.app/Contents/Library/LaunchServices/com.guigx.macicns.helper
test ! -e /Applications/MacICNS.app/Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist
shasum -a 256 \
  /private/tmp/macicns-install-derived/Build/Products/Debug/MacICNS.app/Contents/MacOS/MacICNS \
  /Applications/MacICNS.app/Contents/MacOS/MacICNS
open /Applications/MacICNS.app
```

Expected: build number is `8`, signature is valid, helper artifacts are absent, executable checksums match, and the installed app opens.

- [ ] **Step 6: Report the recoverable backup and testing instructions**

Report the exact backup path and ask the user to verify:

1. Close the management window with the red button.
2. Confirm MacICNS disappears from the Dock but remains in the menu bar.
3. Select `Show MacICNS` and confirm the window and Dock icon return.
4. Confirm `Refresh Icons` and `Quit` remain available.
