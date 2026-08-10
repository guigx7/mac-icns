import Foundation
import XCTest
@testable import MacICNS

final class MappingEligibilityPrunerTests: XCTestCase {
    func testPruneRemovesUnsupportedButRetainsCompatibleAndMissingMappings() {
        let compatibleURL = URL(filePath: "/Applications/Compatible.app")
        let protectedURL = URL(filePath: "/Applications/Protected.app")
        let systemURL = URL(filePath: "/System/Applications/System.app")
        let invalidURL = URL(filePath: "/Applications/Invalid.app")
        let missingURL = URL(filePath: "/Applications/Missing.app")
        let compatible = mapping(at: compatibleURL)
        let protected = mapping(at: protectedURL)
        let system = mapping(at: systemURL)
        let invalid = mapping(at: invalidURL)
        let missing = mapping(at: missingURL)
        let pruner = MappingEligibilityPruner(
            eligibility: PrunerEligibilityStub(values: [
                compatibleURL: .compatible,
                protectedURL: .protected,
                systemURL: .systemApplication,
                invalidURL: .invalid,
                missingURL: .missing,
            ]),
            locator: PrunerLocatorStub(values: [:])
        )

        let result = pruner.prune([compatible, protected, system, invalid, missing])

        XCTAssertEqual(result.map(\.id), [compatible.id, missing.id])
    }

    func testMissingMappingUsesCompatibleLocatedApplication() throws {
        let missingURL = URL(filePath: "/Applications/Old.app")
        let recoveredURL = URL(filePath: "/Users/example/Applications/Recovered.app")
        let missing = mapping(at: missingURL, bundleIdentifier: "com.example.recovered")
        let pruner = MappingEligibilityPruner(
            eligibility: PrunerEligibilityStub(values: [
                missingURL: .missing,
                recoveredURL: .compatible,
            ]),
            locator: PrunerLocatorStub(values: ["com.example.recovered": recoveredURL])
        )

        let result = try XCTUnwrap(pruner.prune([missing]).first)

        XCTAssertEqual(result.id, missing.id)
        XCTAssertEqual(result.applicationURL, recoveredURL.standardizedFileURL)
    }

    func testMissingMappingIsRemovedWhenLocatedApplicationIsProtected() {
        let missingURL = URL(filePath: "/Applications/Old.app")
        let protectedURL = URL(filePath: "/Applications/Recovered.app")
        let missing = mapping(at: missingURL, bundleIdentifier: "com.example.recovered")
        let pruner = MappingEligibilityPruner(
            eligibility: PrunerEligibilityStub(values: [
                missingURL: .missing,
                protectedURL: .protected,
            ]),
            locator: PrunerLocatorStub(values: ["com.example.recovered": protectedURL])
        )

        XCTAssertTrue(pruner.prune([missing]).isEmpty)
    }

    private func mapping(
        at applicationURL: URL,
        bundleIdentifier: String? = nil
    ) -> IconMapping {
        IconMapping(
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            iconURL: URL(filePath: "/tmp/Icon.icns")
        )
    }
}

private struct PrunerEligibilityStub: ApplicationEligibilityChecking {
    let values: [URL: ApplicationEligibility]

    func eligibility(for applicationURL: URL) -> ApplicationEligibility {
        values[applicationURL] ?? .invalid
    }
}

private struct PrunerLocatorStub: ApplicationLocating {
    let values: [String: URL]

    func resolve(_ bundleIdentifier: String) -> URL? {
        values[bundleIdentifier]
    }
}
