import Foundation
import XCTest
@testable import MacICNS

final class ApplicationEligibilityServiceTests: XCTestCase {
    func testWritableApplicationIsCompatible() {
        let applicationURL = URL(filePath: "/Applications/Example.app")
        let service = service(
            inspecting: applicationURL,
            exists: true,
            isDirectory: true,
            volumeIsReadOnly: false,
            isWritable: true
        )

        XCTAssertEqual(service.eligibility(for: applicationURL), .compatible)
    }

    func testUnwritableApplicationIsProtected() {
        let applicationURL = URL(filePath: "/Applications/Protected.app")
        let service = service(
            inspecting: applicationURL,
            exists: true,
            isDirectory: true,
            volumeIsReadOnly: false,
            isWritable: false
        )

        XCTAssertEqual(service.eligibility(for: applicationURL), .protected)
    }

    func testApplicationOnReadOnlyVolumeIsProtected() {
        let applicationURL = URL(filePath: "/Volumes/ReadOnly/Example.app")
        let service = service(
            inspecting: applicationURL,
            exists: true,
            isDirectory: true,
            volumeIsReadOnly: true,
            isWritable: true
        )

        XCTAssertEqual(service.eligibility(for: applicationURL), .protected)
    }

    func testSystemApplicationIsNeverCompatible() {
        let applicationURL = URL(filePath: "/System/Applications/FindMy.app")
        let service = service(
            inspecting: applicationURL,
            exists: true,
            isDirectory: true,
            volumeIsReadOnly: false,
            isWritable: true
        )

        XCTAssertEqual(service.eligibility(for: applicationURL), .systemApplication)
    }

    func testMissingApplicationIsMissing() {
        let applicationURL = URL(filePath: "/Applications/Missing.app")
        let service = service(
            inspecting: applicationURL,
            exists: false,
            isDirectory: false,
            volumeIsReadOnly: false,
            isWritable: false
        )

        XCTAssertEqual(service.eligibility(for: applicationURL), .missing)
    }

    func testNonApplicationURLIsInvalid() {
        let service = ApplicationEligibilityService { url in
            ApplicationInspection(
                resolvedURL: url,
                exists: true,
                isDirectory: true,
                volumeIsReadOnly: false,
                isWritable: true
            )
        }

        XCTAssertEqual(
            service.eligibility(for: URL(filePath: "/Applications/NotAnApplication")),
            .invalid
        )
    }

    func testInspectionFailureIsInvalid() {
        let service = ApplicationEligibilityService { _ in
            throw CocoaError(.fileReadNoSuchFile)
        }

        XCTAssertEqual(
            service.eligibility(for: URL(filePath: "/Applications/BrokenLink.app")),
            .invalid
        )
    }

    func testResolvedWritableApplicationLinkIsCompatible() {
        let linkURL = URL(filePath: "/Applications/Example Link.app")
        let resolvedURL = URL(filePath: "/Users/example/Applications/Example.app")
        let service = service(
            inspecting: resolvedURL,
            exists: true,
            isDirectory: true,
            volumeIsReadOnly: false,
            isWritable: true
        )

        XCTAssertEqual(service.eligibility(for: linkURL), .compatible)
    }

    private func service(
        inspecting resolvedURL: URL,
        exists: Bool,
        isDirectory: Bool,
        volumeIsReadOnly: Bool,
        isWritable: Bool
    ) -> ApplicationEligibilityService {
        ApplicationEligibilityService { _ in
            ApplicationInspection(
                resolvedURL: resolvedURL,
                exists: exists,
                isDirectory: isDirectory,
                volumeIsReadOnly: volumeIsReadOnly,
                isWritable: isWritable
            )
        }
    }
}
