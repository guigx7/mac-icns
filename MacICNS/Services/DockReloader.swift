import Foundation

protocol DockReloading: Sendable {
    func reload() async throws
}

protocol DockProcessLaunching: Sendable {
    func launch(executableURL: URL, arguments: [String]) async throws -> Int32
}

enum DockReloadError: LocalizedError, Equatable {
    case launchFailed
    case nonZeroExit(Int32)

    var errorDescription: String? {
        switch self {
        case .launchFailed: "Could not reload the Dock."
        case .nonZeroExit: "The Dock did not reload successfully."
        }
    }
}

struct DockReloader: DockReloading {
    private let launcher: any DockProcessLaunching

    init(launcher: any DockProcessLaunching = FoundationDockProcessLauncher()) {
        self.launcher = launcher
    }

    func reload() async throws {
        let status: Int32
        do {
            status = try await launcher.launch(
                executableURL: URL(filePath: "/usr/bin/killall"),
                arguments: ["Dock"]
            )
        } catch {
            throw DockReloadError.launchFailed
        }
        guard status == 0 else { throw DockReloadError.nonZeroExit(status) }
    }
}

struct FoundationDockProcessLauncher: DockProcessLaunching {
    func launch(executableURL: URL, arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
