import Darwin
import Foundation
import XCTest
@testable import MacICNS

final class PrivilegedIconWriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(path: "MacICNS-PrivilegedIconWriter-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testOpensRootOwnedApplicationBelowGroupWritableApplicationsDirectory() throws {
        let applicationURL = URL(filePath: "/Applications/Xcode.app", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw XCTSkip("Xcode.app is not installed in /Applications on this Mac")
        }

        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(applicationURL: applicationURL)
        defer { close(descriptor) }

        var metadata = stat()
        XCTAssertEqual(fstat(descriptor, &metadata), 0)
        XCTAssertEqual(metadata.st_uid, 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
    }

    func testRejectsWritableFinalApplicationDirectory() throws {
        let applicationURL = temporaryDirectory.appending(path: "Writable.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(applicationURL.path, 0o777), 0)

        XCTAssertThrowsError(
            try PrivilegedPathValidator.openApplicationDirectory(
                applicationURL: applicationURL,
                requiredOwnerUID: getuid()
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedPathValidator.ValidationError,
                .targetIsMutableByUnprivilegedUser
            )
        }
    }

    func testRejectsIntermediateSymlink() throws {
        let realDirectory = temporaryDirectory.appending(path: "Real", directoryHint: .isDirectory)
        let applicationURL = realDirectory.appending(path: "Example.app", directoryHint: .isDirectory)
        let aliasDirectory = temporaryDirectory.appending(path: "Alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)

        XCTAssertThrowsError(
            try PrivilegedPathValidator.openApplicationDirectory(
                applicationURL: aliasDirectory.appending(path: "Example.app", directoryHint: .isDirectory),
                requiredOwnerUID: getuid()
            )
        ) { error in
            XCTAssertEqual(error as? PrivilegedPathValidator.ValidationError, .unsafePath)
        }
    }

    func testRejectsFinalApplicationSymlink() throws {
        let realApplicationURL = temporaryDirectory.appending(path: "Real.app", directoryHint: .isDirectory)
        let symlinkURL = temporaryDirectory.appending(path: "Alias.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realApplicationURL, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realApplicationURL)

        XCTAssertThrowsError(
            try PrivilegedPathValidator.openApplicationDirectory(
                applicationURL: symlinkURL,
                requiredOwnerUID: getuid()
            )
        ) { error in
            XCTAssertEqual(error as? PrivilegedPathValidator.ValidationError, .unsafePath)
        }
    }
}
