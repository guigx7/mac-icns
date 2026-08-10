import Foundation

struct PrivilegedHelperClient: IconApplying, Sendable {
    private let connectionFactory: @Sendable () -> NSXPCConnection

    init(connectionFactory: @escaping @Sendable () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: "com.guigx.macicns.helper", options: .privileged)
    }) {
        self.connectionFactory = connectionFactory
    }

    func protocolVersion() async throws -> Int {
        let connection = connectionFactory()
        let completion = XPCCompletion<Int>()

        return try await withCheckedThrowingContinuation { continuation in
            completion.continuation = continuation
            configure(connection, completion: completion)
            connection.resume()

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
                completion.finish(.failure(CocoaError(.fileReadUnknown)))
            }) as? IconHelperXPCProtocol else {
                completion.finish(.failure(CocoaError(.fileReadUnknown)))
                connection.invalidate()
                return
            }

            helper.protocolVersion { version in
                completion.finish(.success(version))
                connection.invalidate()
            }
        }
    }

    func apply(applicationURL: URL, iconURL: URL) async throws {
        let request = try await MainActor.run {
            try IconApplyRequest(applicationURL: applicationURL, iconURL: iconURL)
        }
        try await apply(request)
    }

    func apply(_ request: IconApplyRequest) async throws {
        let connection = connectionFactory()
        let completion = XPCCompletion<Void>()

        try await withCheckedThrowingContinuation { continuation in
            completion.continuation = continuation
            configure(connection, completion: completion)
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

    func reset(applicationURL: URL) async throws {
        try await reset(IconResetRequest(applicationURL: applicationURL))
    }

    func reset(_ request: IconResetRequest) async throws {
        let connection = connectionFactory()
        let completion = XPCCompletion<Void>()

        try await withCheckedThrowingContinuation { continuation in
            completion.continuation = continuation
            configure(connection, completion: completion)
            connection.resume()

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
                completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
            }) as? IconHelperXPCProtocol else {
                completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
                connection.invalidate()
                return
            }

            helper.resetIcon(request) { error in
                completion.finish(error.map { .failure($0) } ?? .success(()))
                connection.invalidate()
            }
        }
    }

    private func configure<Value: Sendable>(
        _ connection: NSXPCConnection,
        completion: XPCCompletion<Value>
    ) {
        connection.remoteObjectInterface = NSXPCInterface(with: IconHelperXPCProtocol.self)
        connection.setCodeSigningRequirement(CodeSigningRequirements.helper)
        connection.interruptionHandler = {
            completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
        }
        connection.invalidationHandler = {
            completion.finish(.failure(CocoaError(.fileWriteNoPermission)))
        }
    }
}

private final class XPCCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFinished = false
    var continuation: CheckedContinuation<Value, Error>?

    func finish(_ result: Result<Value, Error>) {
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
