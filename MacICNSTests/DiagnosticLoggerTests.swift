import Foundation
import XCTest
@testable import MacICNS

final class DiagnosticLoggerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var temporaryLogURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        temporaryLogURL = temporaryDirectory.appending(path: "diagnostics.log")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        temporaryLogURL = nil
    }

    func testLogIsLocalAndCopyable() throws {
        let logger = DiagnosticLogger(fileURL: temporaryLogURL)

        try logger.record("helper unavailable")

        XCTAssertTrue(try logger.copyableContents().contains("helper unavailable"))
    }

    func testRotationKeepsEachPreviousLog() throws {
        let logger = DiagnosticLogger(fileURL: temporaryLogURL, maximumFileSize: 80)
        let fullLog = Data(repeating: 0x61, count: 79)

        try fullLog.write(to: temporaryLogURL)
        try logger.record("first refresh")
        try fullLog.write(to: temporaryLogURL)
        try logger.record("second refresh")

        let archivedLogs = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("diagnostics-") }
        XCTAssertEqual(archivedLogs.count, 2)
        XCTAssertTrue(try logger.copyableContents().contains("second refresh"))
    }
}
