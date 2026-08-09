import AppKit
import ServiceManagement

@MainActor
final class HelperInstallationService {
    enum Status: Equatable {
        case notInstalled
        case installed
        case requiresApproval
    }

    private let statusProvider: () -> Status
    private let registerAction: () throws -> Void
    private let unregisterAction: () async throws -> Void
    private let openSettingsAction: () -> Void

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
    }

    init(
        statusProvider: @escaping () -> Status,
        register: @escaping () throws -> Void,
        unregister: @escaping () async throws -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.statusProvider = statusProvider
        registerAction = register
        unregisterAction = unregister
        openSettingsAction = openSettings
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
        try registerAction()
    }

    func openLoginItemsAndExtensions() {
        openSettingsAction()
    }
}
