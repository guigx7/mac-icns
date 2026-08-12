import AppKit
import XCTest
@testable import MacICNS

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
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

    func testApplicationDelegateKeepsProcessAliveAfterLastWindowCloses() {
        let applicationDelegate = MacICNSApplicationDelegate(
            lifecycleController: ApplicationLifecycleController { _ in true },
            visibleWindowProvider: { false }
        )

        XCTAssertFalse(
            applicationDelegate.applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }
}
