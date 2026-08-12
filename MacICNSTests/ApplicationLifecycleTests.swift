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
