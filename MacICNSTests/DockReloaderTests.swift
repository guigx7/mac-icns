import XCTest
@testable import MacICNS

final class DockReloaderTests: XCTestCase {
    func testReloadLaunchesOnlyTheFixedDockCommand() async throws {
        let launcher = RecordingDockProcessLauncher(exitStatus: 0)
        let reloader = DockReloader(launcher: launcher)

        try await reloader.reload()

        let executableURL = await launcher.executableURL
        let arguments = await launcher.arguments
        XCTAssertEqual(executableURL, URL(filePath: "/usr/bin/killall"))
        XCTAssertEqual(arguments, ["Dock"])
    }

    func testReloadSurfacesANonZeroExitStatus() async {
        let reloader = DockReloader(
            launcher: RecordingDockProcessLauncher(exitStatus: 1)
        )

        do {
            try await reloader.reload()
            XCTFail("Expected reload to fail")
        } catch {
            XCTAssertEqual(error as? DockReloadError, .nonZeroExit(1))
        }
    }
}

private actor RecordingDockProcessLauncher: DockProcessLaunching {
    let exitStatus: Int32
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?

    init(exitStatus: Int32) { self.exitStatus = exitStatus }

    func launch(executableURL: URL, arguments: [String]) async throws -> Int32 {
        self.executableURL = executableURL
        self.arguments = arguments
        return exitStatus
    }
}
