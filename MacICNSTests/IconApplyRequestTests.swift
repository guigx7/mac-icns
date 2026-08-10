import Foundation
import XCTest
@testable import MacICNS

@MainActor
final class IconApplyRequestTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var applicationURL: URL!
    private var iconURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        applicationURL = temporaryDirectory.appending(path: "Example.app", directoryHint: .isDirectory)
        iconURL = temporaryDirectory.appending(path: "Example.icns")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try Data(contentsOf: systemIconURL).write(to: iconURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testAcceptsAnExistingApplicationAndLoadableICNS() throws {
        let protectedApplicationURL = URL(
            filePath: "/System/Applications/App Store.app",
            directoryHint: .isDirectory
        )
        let request: IconApplyRequest
        do {
            request = try IconApplyRequest(applicationURL: protectedApplicationURL, iconURL: systemIconURL)
        } catch {
            XCTFail("Expected the fixture to be accepted, got \(error)")
            return
        }

        XCTAssertEqual(request.applicationURL, protectedApplicationURL.standardizedFileURL)
        XCTAssertEqual(request.iconURL, systemIconURL.standardizedFileURL)
        XCTAssertNoThrow(try PrivilegedPathValidator.validate(applicationURL: protectedApplicationURL))
    }

    func testSecureCodingRoundTripDoesNotReopenTheSourceIcon() throws {
        let protectedApplicationURL = URL(
            filePath: "/System/Applications/App Store.app",
            directoryHint: .isDirectory
        )
        let detachedDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
            .appending(path: "MacICNS-XPCRoundTrip-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: detachedDirectory) }
        try FileManager.default.createDirectory(at: detachedDirectory, withIntermediateDirectories: true)
        let detachedIconURL = detachedDirectory.appending(path: "Detached.icns")
        try Data(contentsOf: systemIconURL).write(to: detachedIconURL)
        let request = try IconApplyRequest(
            applicationURL: protectedApplicationURL,
            iconURL: detachedIconURL
        )
        let archivedRequest = try NSKeyedArchiver.archivedData(
            withRootObject: request,
            requiringSecureCoding: true
        )
        try FileManager.default.removeItem(at: detachedIconURL)

        let decodedRequest = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: IconApplyRequest.self, from: archivedRequest)
        )

        XCTAssertEqual(decodedRequest.applicationURL, protectedApplicationURL.standardizedFileURL)
        XCTAssertFalse(decodedRequest.finderIconMetadata.resourceFork.isEmpty)
        XCTAssertEqual(decodedRequest.finderIconMetadata.iconFinderInfo.count, 32)
    }

    func testResetAcceptsAnExistingApplication() throws {
        let protectedApplicationURL = URL(
            filePath: "/System/Applications/App Store.app",
            directoryHint: .isDirectory
        )

        let request = try IconResetRequest(applicationURL: protectedApplicationURL)

        XCTAssertEqual(request.applicationURL, protectedApplicationURL.standardizedFileURL)
    }

    func testResetRejectsNonApplicationTarget() throws {
        let regularFileURL = temporaryDirectory.appending(path: "NotAnApp.app")
        try Data().write(to: regularFileURL)

        XCTAssertThrowsError(try IconResetRequest(applicationURL: regularFileURL))
    }

    func testResetRejectsLeafSymlink() throws {
        let symlinkURL = temporaryDirectory.appending(path: "ResetLinked.app")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: applicationURL)

        XCTAssertThrowsError(try IconResetRequest(applicationURL: symlinkURL))
    }

    func testResetRejectsIntermediateSymlink() throws {
        let symlinkDirectoryURL = temporaryDirectory.appending(path: "ResetAlias", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkDirectoryURL, withDestinationURL: temporaryDirectory)

        XCTAssertThrowsError(
            try IconResetRequest(
                applicationURL: symlinkDirectoryURL.appending(path: "Example.app", directoryHint: .isDirectory)
            )
        )
    }

    func testRejectsNonApplicationTarget() throws {
        let regularFileURL = temporaryDirectory.appending(path: "NotAnApp.app")
        try Data().write(to: regularFileURL)

        XCTAssertThrowsError(try IconApplyRequest(applicationURL: regularFileURL, iconURL: iconURL))
    }

    func testRejectsNonICNSIcon() throws {
        let renamedIconURL = temporaryDirectory.appending(path: "Example.png")
        try Data(contentsOf: iconURL).write(to: renamedIconURL)

        XCTAssertThrowsError(try IconApplyRequest(applicationURL: applicationURL, iconURL: renamedIconURL))
    }

    func testRejectsAnInvalidICNSFile() throws {
        let invalidIconURL = temporaryDirectory.appending(path: "Invalid.icns")
        try Data("not an icon".utf8).write(to: invalidIconURL)

        XCTAssertThrowsError(try IconApplyRequest(applicationURL: applicationURL, iconURL: invalidIconURL))
    }

    func testRejectsLeafSymlink() throws {
        let symlinkURL = temporaryDirectory.appending(path: "Linked.app")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: applicationURL)

        XCTAssertThrowsError(try IconApplyRequest(applicationURL: symlinkURL, iconURL: iconURL))
    }

    func testRejectsIntermediateSymlink() throws {
        let symlinkDirectoryURL = temporaryDirectory.appending(path: "Alias", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkDirectoryURL, withDestinationURL: temporaryDirectory)

        XCTAssertThrowsError(
            try IconApplyRequest(
                applicationURL: symlinkDirectoryURL.appending(path: "Example.app", directoryHint: .isDirectory),
                iconURL: iconURL
            )
        )
    }

    func testRejectsAUserWritablePrivilegedTarget() throws {
        XCTAssertThrowsError(
            try PrivilegedPathValidator.validate(applicationURL: applicationURL)
        )
    }

    func testCodeSigningRequirementsBindBothIdentifiersToTheKnownTeam() {
        XCTAssertEqual(
            CodeSigningRequirements.client,
            "identifier \"com.guigx.macicns\" and anchor apple generic and certificate leaf[subject.OU] = \"DHAFYHA4FG\""
        )
        XCTAssertEqual(
            CodeSigningRequirements.helper,
            "identifier \"com.guigx.macicns.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"DHAFYHA4FG\""
        )
    }
}

private let systemIconURL = URL(filePath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
