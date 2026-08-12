import XCTest
@testable import MacICNS

final class JSONMappingRepositoryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testRoundTripPreservesMapping() throws {
        let url = temporaryDirectory.appending(path: "mappings.json")
        let repository = JSONMappingRepository(fileURL: url)
        let mapping = IconMapping(
            applicationURL: URL(filePath: "/Applications/Test.app"),
            bundleIdentifier: "com.example.Test",
            iconURL: URL(filePath: "/tmp/Test.icns")
        )

        try repository.save([mapping])

        XCTAssertEqual(try repository.load(), [mapping])
    }

    func testLoadReturnsEmptyArrayWhenFileIsMissing() throws {
        let url = temporaryDirectory.appending(path: "mappings.json")
        let repository = JSONMappingRepository(fileURL: url)

        XCTAssertEqual(try repository.load(), [])
    }

    func testLegacyMappingWithoutEnabledFieldDefaultsToEnabled() throws {
        let url = temporaryDirectory.appending(path: "mappings.json")
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "applicationURL":"file:///Applications/Test.app/",
          "bundleIdentifier":"com.example.Test",
          "iconURL":"file:///tmp/Test.icns",
          "status":"upToDate"
        }]
        """
        try Data(json.utf8).write(to: url)

        let mapping = try JSONMappingRepository(fileURL: url).load().first

        XCTAssertEqual(mapping?.isEnabled, true)
    }

    func testRoundTripPreservesDisabledState() throws {
        let url = temporaryDirectory.appending(path: "mappings.json")
        let repository = JSONMappingRepository(fileURL: url)
        var mapping = IconMapping(
            applicationURL: URL(filePath: "/Applications/Test.app"),
            bundleIdentifier: "com.example.Test",
            iconURL: URL(filePath: "/tmp/Test.icns")
        )
        mapping.isEnabled = false

        try repository.save([mapping])

        XCTAssertEqual(try repository.load().first?.isEnabled, false)
    }

    func testRoundTripPreservesRestartRequiredStatus() throws {
        let url = temporaryDirectory.appending(path: "mappings.json")
        let repository = JSONMappingRepository(fileURL: url)
        var mapping = IconMapping(
            applicationURL: URL(filePath: "/Applications/Test.app"),
            bundleIdentifier: "com.example.Test",
            iconURL: URL(filePath: "/tmp/Test.icns")
        )
        mapping.status = .restartRequired

        try repository.save([mapping])

        XCTAssertEqual(try repository.load().first?.status, .restartRequired)
    }
}
