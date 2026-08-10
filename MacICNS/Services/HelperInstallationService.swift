import AppKit
import ServiceManagement

@MainActor
final class HelperInstallationService {
    enum Status: Equatable {
        case notInstalled
        case installed
        case requiresApproval
    }

    enum UpdateError: LocalizedError {
        case registrationTimedOut

        var errorDescription: String? {
            switch self {
            case .registrationTimedOut:
                "macOS did not finish updating the helper. Please try again."
            }
        }
    }

    private let statusProvider: () -> Status
    private let registerAction: () throws -> Void
    private let unregisterAction: () async throws -> Void
    private let openSettingsAction: () -> Void
    private let registrationRetryLimit: Int
    private let registrationRetryDelay: () async throws -> Void

    init(service: SMAppService = .daemon(plistName: "com.guigx.macicns.helper.plist")) {
        statusProvider = {
            switch service.status {
            case .enabled:
                .installed
            case .requiresApproval:
                .requiresApproval
            default:
                .notInstalled
            }
        }
        registerAction = { try service.register() }
        unregisterAction = {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                service.unregister { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        openSettingsAction = {
            guard let settingsURL = URL(
                string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            ) else {
                return
            }
            NSWorkspace.shared.open(settingsURL)
        }
        registrationRetryLimit = 40
        registrationRetryDelay = {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    init(
        statusProvider: @escaping () -> Status,
        register: @escaping () throws -> Void,
        unregister: @escaping () async throws -> Void,
        openSettings: @escaping () -> Void,
        registrationRetryLimit: Int = 40,
        registrationRetryDelay: @escaping () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.statusProvider = statusProvider
        registerAction = register
        unregisterAction = unregister
        openSettingsAction = openSettings
        self.registrationRetryLimit = max(1, registrationRetryLimit)
        self.registrationRetryDelay = registrationRetryDelay
    }

    var status: Status {
        statusProvider()
    }

    func install() throws {
        try registerAction()
    }

    func remove() async throws {
        try await unregisterAction()
    }

    func update() async throws {
        do {
            try await unregisterAction()
        } catch {
            guard statusProvider() == .notInstalled else {
                throw error
            }
        }
        try await registerAfterRemoval()
    }

    private func registerAfterRemoval() async throws {
        for attempt in 1...registrationRetryLimit {
            do {
                try registerAction()
                return
            } catch where isTransientRegistrationFailure(error) {
                guard attempt < registrationRetryLimit else {
                    throw UpdateError.registrationTimedOut
                }
                try await registrationRetryDelay()
            }
        }
    }

    private func isTransientRegistrationFailure(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "SMAppServiceErrorDomain" && error.code == 1
    }

    func openLoginItemsAndExtensions() {
        openSettingsAction()
    }
}
