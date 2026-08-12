import AppKit

protocol ApplicationRunningChecking: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
}

protocol ApplicationIdentity {
    var bundleIdentifier: String? { get }
}

extension NSRunningApplication: ApplicationIdentity {}

@MainActor
protocol ApplicationTerminationObserving: AnyObject {
    func startObservingTerminations(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    )
    func stopObservingTerminations()
}

final class WorkspaceApplicationRuntime: ApplicationRunningChecking, @unchecked Sendable {
    static let shared = WorkspaceApplicationRuntime()

    private let notificationCenter: NotificationCenter
    @MainActor private var observerToken: (any NSObjectProtocol)?

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func isRunning(bundleIdentifier: String) async -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }
}

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
        guard let observerToken else {
            return
        }
        notificationCenter.removeObserver(observerToken)
        self.observerToken = nil
    }
}
