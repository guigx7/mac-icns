import Foundation

struct PrivilegedHelperClient: IconApplying, Sendable {
    private let connectionFactory: @Sendable () -> NSXPCConnection

    init(connectionFactory: @escaping @Sendable () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: "com.guigx.macicns.helper", options: .privileged)
    }) {
        self.connectionFactory = connectionFactory
    }

    func apply(applicationURL: URL, iconURL: URL) async throws {
        try await apply(IconApplyRequest(applicationURL: applicationURL, iconURL: iconURL))
    }

    func apply(_ request: IconApplyRequest) async throws {
        let connection = connectionFactory()
        let completion = XPCCompletion()

        try await withCheckedThrowingContinuation { continuation in
            completion.continuation = continuation
            connection.remoteObjectInterface = NSXPCInterface(with: IconHelperXPCProtocol.self)
            connection.setCodeSigningRequirement(
                "identifier \"com.guigx.macicns.helper\" and anchor apple generic"
            )
            connection.interruptionHandler = {
                completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
            }
            connection.invalidationHandler = {
                completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
            }
            connection.resume()

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
                completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
            }) as? IconHelperXPCProtocol else {
                completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
                connection.invalidate()
                return
            }

            helper.applyIcon(request) { error in
                if let error {
                    completion.finish(.failure(error))
                } else {
                    completion.finish(.success(()))
                }
                connection.invalidate()
            }
        }
    }
}

private final class XPCCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFinished = false
    var continuation: CheckedContinuation<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasFinished, let continuation else {
            return
        }
        hasFinished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}
