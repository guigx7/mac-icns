import Darwin
import AppKit
import Foundation
import XCTest
@testable import MacICNS

final class PrivilegedIconWriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
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

    func testApplyCreatesIconResourceForkAndSetsCustomIconFlag() throws {
        let applicationURL = try makeApplication(named: "Apply.app")
        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: applicationURL,
            requiredOwnerUID: getuid()
        )
        defer { close(descriptor) }
        let image = try XCTUnwrap(NSImage(contentsOf: systemIconURL))

        try StableApplicationIconWriter().apply(
            image: image,
            toApplicationDescriptor: descriptor
        )

        let iconDescriptor = openat(descriptor, "Icon\r", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(iconDescriptor, 0)
        if iconDescriptor >= 0 {
            defer { close(iconDescriptor) }
            XCTAssertGreaterThan(xattrSize(descriptor: iconDescriptor, name: "com.apple.ResourceFork"), 0)
        }
        XCTAssertEqual(finderFlags(descriptor: descriptor) & 0x0400, 0x0400)
    }

    func testResetRemovesIconAndClearsOnlyCustomIconFlag() throws {
        let applicationURL = try makeApplication(named: "Reset.app")
        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: applicationURL,
            requiredOwnerUID: getuid()
        )
        defer { close(descriptor) }
        let image = try XCTUnwrap(NSImage(contentsOf: systemIconURL))
        try StableApplicationIconWriter().apply(image: image, toApplicationDescriptor: descriptor)
        try setFinderFlags(0x2400, descriptor: descriptor)

        try StableApplicationIconWriter().reset(applicationDescriptor: descriptor)

        errno = 0
        let iconDescriptor = openat(descriptor, "Icon\r", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertEqual(iconDescriptor, -1)
        XCTAssertEqual(errno, ENOENT)
        XCTAssertEqual(finderFlags(descriptor: descriptor) & 0x2400, 0x2000)
    }

    func testApplyRejectsSymlinkedIconMetadataFile() throws {
        let applicationURL = try makeApplication(named: "SymlinkedIcon.app")
        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: applicationURL,
            requiredOwnerUID: getuid()
        )
        defer { close(descriptor) }
        let outsideFileURL = temporaryDirectory.appending(path: "Outside")
        try Data("unchanged".utf8).write(to: outsideFileURL)
        try FileManager.default.createSymbolicLink(
            at: applicationURL.appending(path: "Icon\r"),
            withDestinationURL: outsideFileURL
        )
        let image = try XCTUnwrap(NSImage(contentsOf: systemIconURL))

        XCTAssertThrowsError(
            try StableApplicationIconWriter().apply(
                image: image,
                toApplicationDescriptor: descriptor
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideFileURL), Data("unchanged".utf8))
    }

    func testApplyRejectsHardLinkedIconMetadataFile() throws {
        let applicationURL = try makeApplication(named: "HardLinkedIcon.app")
        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: applicationURL,
            requiredOwnerUID: getuid()
        )
        defer { close(descriptor) }
        let outsideFileURL = temporaryDirectory.appending(path: "HardLinkOutside")
        try Data("unchanged".utf8).write(to: outsideFileURL)
        XCTAssertEqual(
            link(outsideFileURL.path, applicationURL.appending(path: "Icon\r").path),
            0
        )
        let image = try XCTUnwrap(NSImage(contentsOf: systemIconURL))

        XCTAssertThrowsError(
            try StableApplicationIconWriter().apply(
                image: image,
                toApplicationDescriptor: descriptor
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideFileURL), Data("unchanged".utf8))
    }

    func testPrivilegedOperationAppliesValidatedRequest() throws {
        let applicationURL = try makeApplication(named: "OperationApply.app")
        let request = try IconApplyRequest(applicationURL: applicationURL, iconURL: systemIconURL)
        let operation = PrivilegedIconOperation(requiredOwnerUID: getuid())

        try operation.apply(request: request)

        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: applicationURL,
            requiredOwnerUID: getuid()
        )
        defer { close(descriptor) }
        XCTAssertEqual(finderFlags(descriptor: descriptor) & 0x0400, 0x0400)
        let iconDescriptor = openat(descriptor, "Icon\r", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(iconDescriptor, 0)
        if iconDescriptor >= 0 { close(iconDescriptor) }
    }

    func testPrivilegedOperationUsesRequestBytesAfterSourceIconIsRemoved() throws {
        let applicationURL = try makeApplication(named: "DetachedSourceApply.app")
        let iconURL = temporaryDirectory.appending(path: "DetachedSource.icns")
        try Data(contentsOf: systemIconURL).write(to: iconURL)
        let request = try IconApplyRequest(applicationURL: applicationURL, iconURL: iconURL)
        try FileManager.default.removeItem(at: iconURL)
        let operation = PrivilegedIconOperation(requiredOwnerUID: getuid())

        try operation.apply(request: request)

        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: applicationURL,
            requiredOwnerUID: getuid()
        )
        defer { close(descriptor) }
        XCTAssertEqual(finderFlags(descriptor: descriptor) & 0x0400, 0x0400)
    }

    func testPrivilegedOperationResetsValidatedRequest() throws {
        let applicationURL = try makeApplication(named: "OperationReset.app")
        let applyRequest = try IconApplyRequest(applicationURL: applicationURL, iconURL: systemIconURL)
        let resetRequest = try IconResetRequest(applicationURL: applicationURL)
        let operation = PrivilegedIconOperation(requiredOwnerUID: getuid())
        try operation.apply(request: applyRequest)

        try operation.reset(request: resetRequest)

        let descriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: applicationURL,
            requiredOwnerUID: getuid()
        )
        defer { close(descriptor) }
        XCTAssertEqual(finderFlags(descriptor: descriptor) & 0x0400, 0)
        errno = 0
        XCTAssertEqual(openat(descriptor, "Icon\r", O_RDONLY | O_NOFOLLOW | O_CLOEXEC), -1)
        XCTAssertEqual(errno, ENOENT)
    }

    func testPrivilegedOperationRejectsWritableTarget() throws {
        let applicationURL = try makeApplication(named: "OperationWritable.app")
        let request = try IconApplyRequest(applicationURL: applicationURL, iconURL: systemIconURL)
        XCTAssertEqual(chmod(applicationURL.path, 0o777), 0)
        let operation = PrivilegedIconOperation(requiredOwnerUID: getuid())

        XCTAssertThrowsError(try operation.apply(request: request)) { error in
            XCTAssertEqual(
                error as? PrivilegedPathValidator.ValidationError,
                .targetIsMutableByUnprivilegedUser
            )
        }
    }

    private func makeApplication(named name: String) throws -> URL {
        let applicationURL = temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return applicationURL
    }

    private func xattrSize(descriptor: Int32, name: String) -> Int {
        name.withCString { fgetxattr(descriptor, $0, nil, 0, 0, 0) }
    }

    private func finderFlags(descriptor: Int32) -> UInt16 {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        let count = "com.apple.FinderInfo".withCString {
            fgetxattr(descriptor, $0, &finderInfo, finderInfo.count, 0, 0)
        }
        guard count >= 10 else { return 0 }
        return UInt16(finderInfo[8]) << 8 | UInt16(finderInfo[9])
    }

    private func setFinderFlags(_ flags: UInt16, descriptor: Int32) throws {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = UInt8(flags >> 8)
        finderInfo[9] = UInt8(flags & 0x00ff)
        let result = "com.apple.FinderInfo".withCString {
            fsetxattr(descriptor, $0, &finderInfo, finderInfo.count, 0, 0)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private let systemIconURL = URL(
    filePath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
)
