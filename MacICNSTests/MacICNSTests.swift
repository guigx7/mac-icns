import XCTest
@testable import MacICNS

final class MacICNSTests: XCTestCase {
    func testApplicationBootstraps() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.guigx.macicns")
    }

    func testFileSelectionValidatorAcceptsOnlyExpectedExtensions() {
        XCTAssertTrue(FileSelectionValidator.isApplication(URL(filePath: "/Applications/Example.app")))
        XCTAssertFalse(FileSelectionValidator.isApplication(URL(filePath: "/Applications/Example.icns")))
        XCTAssertTrue(FileSelectionValidator.isIcon(URL(filePath: "/tmp/Icon.icns")))
        XCTAssertFalse(FileSelectionValidator.isIcon(URL(filePath: "/tmp/Icon.png")))
    }

    func testFSEventPathDecoderReadsCStringVector() {
        let first = strdup("/Applications/Spotify.app")!
        let second = strdup("/Applications/Spotify.app/Contents/Info.plist")!
        defer {
            free(first)
            free(second)
        }
        var pointers: [UnsafePointer<CChar>?] = [
            UnsafePointer(first),
            UnsafePointer(second),
        ]

        let pointerCount = pointers.count
        let decoded = pointers.withUnsafeMutableBytes { bytes in
            FSEventPathDecoder.decode(bytes.baseAddress!, count: pointerCount)
        }

        XCTAssertEqual(decoded, [
            "/Applications/Spotify.app",
            "/Applications/Spotify.app/Contents/Info.plist",
        ])
    }

    @MainActor
    func testLaunchingTwiceInitializesOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let logURL = directory.appending(path: "diagnostics.log")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(fileURL: logURL)
        let appState = AppState(
            repository: EmptyMappingRepository(),
            diagnosticLogger: logger
        )

        appState.launch()
        appState.launch()

        let loadedEntries = try logger.copyableContents()
            .split(separator: "\n")
            .filter { $0.contains("Loaded 0 icon mappings.") }
        XCTAssertEqual(loadedEntries.count, 1)
    }
}

private struct EmptyMappingRepository: MappingRepository {
    func load() throws -> [IconMapping] { [] }
    func save(_ mappings: [IconMapping]) throws {}
}
