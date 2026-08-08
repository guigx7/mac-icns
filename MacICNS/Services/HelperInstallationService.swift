import AppKit
import ServiceManagement

@MainActor
final class HelperInstallationService {
    enum Status: Equatable {
        case notInstalled
        case installed
        case requiresApproval
    }

    private let service: SMAppService

    init(service: SMAppService = .daemon(plistName: "com.guigx.macicns.helper.plist")) {
        self.service = service
    }

    var status: Status {
        switch service.status {
        case .enabled:
            .installed
        case .requiresApproval:
            .requiresApproval
        default:
            .notInstalled
        }
    }

    func install() throws {
        try service.register()
    }

    func remove() throws {
        try service.unregister()
    }

    func openLoginItemsAndExtensions() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(settingsURL)
    }
}
