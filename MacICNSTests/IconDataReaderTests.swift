import Darwin
import Foundation
import XCTest
@testable import MacICNS

final class IconDataReaderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testOpensAFIFOInNonBlockingMode() throws {
        let fifoURL = temporaryDirectory.appending(path: "Icon.icns")
        XCTAssertEqual(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)

        let keepAliveDescriptor = open(fifoURL.path, O_RDWR | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(keepAliveDescriptor, 0)
        defer { close(keepAliveDescriptor) }

        let descriptor = try IconDataReader.openWithoutFollowingLinks(at: fifoURL)
        defer { close(descriptor) }

        XCTAssertNotEqual(fcntl(descriptor, F_GETFL) & O_NONBLOCK, 0)
    }

    func testRejectsAFIFOAfterOpeningIt() throws {
        let fifoURL = temporaryDirectory.appending(path: "Icon.icns")
        XCTAssertEqual(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)

        let keepAliveDescriptor = open(fifoURL.path, O_RDWR | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(keepAliveDescriptor, 0)
        defer { close(keepAliveDescriptor) }

        XCTAssertThrowsError(try IconDataReader.image(at: fifoURL)) { error in
            XCTAssertEqual(error as? IconDataReader.ReadError, .unsafePath)
        }
    }

    func testRejectsAnOversizedIconBeforeReadingIt() throws {
        let oversizedURL = temporaryDirectory.appending(path: "Oversized.icns")
        let descriptor = open(oversizedURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, IconDataReader.maximumIconByteCount + 1), 0)

        XCTAssertThrowsError(try IconDataReader.image(at: oversizedURL)) { error in
            XCTAssertEqual(error as? IconDataReader.ReadError, .iconIsTooLarge)
        }
    }
}
