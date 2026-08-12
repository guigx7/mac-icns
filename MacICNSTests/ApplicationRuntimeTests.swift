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

    func testStoppingTerminationObservationSuppressesLaterNotifications() async {
        let center = NotificationCenter()
        let runtime = WorkspaceApplicationRuntime(notificationCenter: center)
        let unexpectedTermination = expectation(description: "unexpected termination")
        unexpectedTermination.isInverted = true
        runtime.startObservingTerminations { _ in
            unexpectedTermination.fulfill()
        }
        runtime.stopObservingTerminations()

        center.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: RuntimeApplicationStub(
                bundleIdentifier: "com.example.Target"
            )]
        )

        await fulfillment(of: [unexpectedTermination], timeout: 0.1)
    }

    func testRepeatedStartReplacesTheTerminationHandler() async {
        let center = NotificationCenter()
        let runtime = WorkspaceApplicationRuntime(notificationCenter: center)
        let secondHandlerCalled = expectation(description: "second termination handler")
        var firstHandlerCallCount = 0
        var secondHandlerCallCount = 0
        runtime.startObservingTerminations { _ in
            firstHandlerCallCount += 1
        }
        runtime.startObservingTerminations { _ in
            secondHandlerCallCount += 1
            secondHandlerCalled.fulfill()
        }

        center.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: RuntimeApplicationStub(
                bundleIdentifier: "com.example.Target"
            )]
        )

        await fulfillment(of: [secondHandlerCalled], timeout: 1)
        XCTAssertEqual(firstHandlerCallCount, 0)
        XCTAssertEqual(secondHandlerCallCount, 1)
        runtime.stopObservingTerminations()
    }
}

private final class RuntimeApplicationStub: ApplicationIdentity {
    let bundleIdentifier: String?

    init(bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
    }
}
