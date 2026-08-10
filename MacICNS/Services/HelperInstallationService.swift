import AppKit
import ServiceManagement

@MainActor
final class HelperInstallationService {
    private static let defaultRegistrationRetryLimit = 120
    private static let defaultReadinessRetryLimit = 40

    enum Status: Equatable {
        case notInstalled
        case installed
        case requiresApproval
    }

    enum OperationalStatus: Equatable {
        case notInstalled
        case installed
        case requiresApproval
        case updateRequired
        case unavailable
    }

    enum UpdateError: LocalizedError {
        case requiresApproval
        case helperDidNotBecomeReady

        var errorDescription: String? {
            switch self {
            case .requiresApproval:
                "The helper needs approval in Login Items & Extensions."
            case .helperDidNotBecomeReady:
                "The registered helper did not become ready. Please update it and try again."
            }
        }
    }

    private let statusProvider: () -> Status
    private let registerAction: () throws -> Void
    private let unregisterAction: () async throws -> Void
    private let openSettingsAction: () -> Void
    private let openAppManagementSettingsAction: () -> Void
    private let registrationRetryLimit: Int
    private let registrationRetryDelay: () async throws -> Void
    private let versionProvider: () async throws -> Int
    private let readinessRetryLimit: Int
    private let readinessRetryDelay: () async throws -> Void

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
            SMAppService.openSystemSettingsLoginItems()
        }
        openAppManagementSettingsAction = {
            guard let settingsURL = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
            ) else {
                return
            }
            NSWorkspace.shared.open(settingsURL)
        }
        registrationRetryLimit = Self.defaultRegistrationRetryLimit
        registrationRetryDelay = {
            try await Task.sleep(for: .milliseconds(250))
        }
        versionProvider = {
            try await PrivilegedHelperClient().protocolVersion()
        }
        readinessRetryLimit = Self.defaultReadinessRetryLimit
        readinessRetryDelay = {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    init(
        statusProvider: @escaping () -> Status,
        register: @escaping () throws -> Void,
        unregister: @escaping () async throws -> Void,
        openSettings: @escaping () -> Void,
        openAppManagementSettings: @escaping () -> Void = {},
        versionProvider: @escaping () async throws -> Int = { HelperProtocolVersion.current },
        registrationRetryLimit: Int = HelperInstallationService.defaultRegistrationRetryLimit,
        registrationRetryDelay: @escaping () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(250))
        },
        readinessRetryLimit: Int = HelperInstallationService.defaultReadinessRetryLimit,
        readinessRetryDelay: @escaping () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.statusProvider = statusProvider
        registerAction = register
        unregisterAction = unregister
        openSettingsAction = openSettings
        openAppManagementSettingsAction = openAppManagementSettings
        self.registrationRetryLimit = max(1, registrationRetryLimit)
        self.registrationRetryDelay = registrationRetryDelay
        self.versionProvider = versionProvider
        self.readinessRetryLimit = max(1, readinessRetryLimit)
        self.readinessRetryDelay = readinessRetryDelay
    }

    var status: Status {
        statusProvider()
    }

    var initialOperationalStatus: OperationalStatus {
        switch statusProvider() {
        case .notInstalled:
            .notInstalled
        case .requiresApproval:
            .requiresApproval
        case .installed:
            .unavailable
        }
    }

    func operationalStatus() async -> OperationalStatus {
        switch statusProvider() {
        case .notInstalled:
            return .notInstalled
        case .requiresApproval:
            return .requiresApproval
        case .installed:
            do {
                let version = try await versionProvider()
                return version == HelperProtocolVersion.current ? .installed : .updateRequired
            } catch {
                return .unavailable
            }
        }
    }

    func installAndWaitUntilReady() async throws {
        do {
            try registerAction()
        } catch where isTransientRegistrationFailure(error) {
            throw UpdateError.requiresApproval
        }
        try await waitUntilReady()
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
        try await waitUntilReady()
    }

    private func registerAfterRemoval() async throws {
        for attempt in 1...registrationRetryLimit {
            do {
                try registerAction()
                return
            } catch where isTransientRegistrationFailure(error) {
                guard attempt < registrationRetryLimit else {
                    throw UpdateError.requiresApproval
                }
                try await registrationRetryDelay()
            }
        }
    }

    private func waitUntilReady() async throws {
        for attempt in 1...readinessRetryLimit {
            if await operationalStatus() == .installed {
                return
            }
            guard attempt < readinessRetryLimit else {
                throw UpdateError.helperDidNotBecomeReady
            }
            try await readinessRetryDelay()
        }
    }

    private func isTransientRegistrationFailure(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "SMAppServiceErrorDomain" && error.code == 1
    }

    func openLoginItemsAndExtensions() {
        openSettingsAction()
    }

    func openAppManagement() {
        openAppManagementSettingsAction()
    }
}
