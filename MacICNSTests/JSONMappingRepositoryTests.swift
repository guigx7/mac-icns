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
}
