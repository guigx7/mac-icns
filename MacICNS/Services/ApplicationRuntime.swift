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
