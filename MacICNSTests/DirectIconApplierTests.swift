import Foundation
import XCTest
@testable import MacICNS

final class DirectIconApplierTests: XCTestCase {
    func testDirectResetClearsTheFinderCustomIcon() async throws {
        let applicationURL = URL(filePath: "/tmp/Example.app")
        let recorder = URLRecorder()
        let applier = DirectIconApplier(
            isApplicationWritable: { _ in true },
            setIcon: { _, _ in true },
            resetIcon: { url in
                await recorder.record(url)
                return true
            }
        )

        try await applier.reset(applicationURL: applicationURL)

        let recordedURLs = await recorder.urls
        XCTAssertEqual(recordedURLs, [applicationURL])
    }

    func testRejectsANonApplicationBundle() async {
        let applier = DirectIconApplier(
            isApplicationWritable: { _ in true },
            setIcon: { _, _ in true }
        )

        do {
            try await applier.apply(
                applicationURL: URL(filePath: "/tmp/Example"),
                iconURL: URL(filePath: "/tmp/Icon.icns")
            )
            XCTFail("Expected a non-application target to be rejected")
        } catch {
            XCTAssertEqual(error as? DirectIconApplier.InputError, .invalidApplicationURL)
        }
    }

    func testUnwritableApplicationProducesNeedsPermissionStatus() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let applicationURL = temporaryDirectory.appending(path: "Example.app", directoryHint: .isDirectory)
        let iconURL = temporaryDirectory.appending(path: "Icon.icns")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: iconURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let applier = DirectIconApplier(
            isApplicationWritable: { _ in false },
            setIcon: { _, _ in
                XCTFail("An unwritable application must not reach NSWorkspace.setIcon")
                return false
            }
        )
        let coordinator = RepairCoordinator(
            fingerprinting: FixedFingerprinting(value: "new"),
            locator: EmptyLocator(),
            applier: applier
        )
        var mapping = IconMapping(
            applicationURL: applicationURL,
            bundleIdentifier: nil,
            iconURL: iconURL
        )
        mapping.appFingerprint = "old-app"
        mapping.iconFingerprint = "old-icon"

        let repaired = await coordinator.repair(mapping, reason: .manual)

        XCTAssertEqual(repaired.status, .needsPermission)
    }
}

private actor URLRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}

private struct FixedFingerprinting: Fingerprinting {
    let value: String

    func fingerprint(of url: URL) throws -> String {
        value
    }
}

private struct EmptyLocator: ApplicationLocating {
    func resolve(_ bundleIdentifier: String) -> URL? {
        nil
    }
}
