import Foundation
import XCTest
@testable import MacICNS

final class ApplicationCatalogTests: XCTestCase {
    func testCompatibleEntriesSortBeforeUnsupportedEntries() {
        let catalog = ApplicationCatalog(entries: [
            ApplicationCatalogEntry(
                url: URL(filePath: "/Applications/Xcode.app"),
                displayName: "Xcode",
                eligibility: .protected
            ),
            ApplicationCatalogEntry(
                url: URL(filePath: "/Applications/Discord.app"),
                displayName: "Discord",
                eligibility: .compatible
            ),
            ApplicationCatalogEntry(
                url: URL(filePath: "/System/Applications/FindMy.app"),
                displayName: "Find My",
                eligibility: .systemApplication
            ),
            ApplicationCatalogEntry(
                url: URL(filePath: "/Applications/Arc.app"),
                displayName: "Arc",
                eligibility: .compatible
            ),
        ])

        XCTAssertEqual(
            catalog.entries(searchText: "").map(\.displayName),
            ["Arc", "Discord", "Find My", "Xcode"]
        )
    }

    func testSearchMatchesApplicationNameCaseInsensitively() {
        let catalog = ApplicationCatalog(entries: [
            ApplicationCatalogEntry(
                url: URL(filePath: "/Applications/Visual Studio Code.app"),
                displayName: "Visual Studio Code",
                eligibility: .compatible
            ),
            ApplicationCatalogEntry(
                url: URL(filePath: "/Applications/Discord.app"),
                displayName: "Discord",
                eligibility: .compatible
            ),
        ])

        XCTAssertEqual(
            catalog.entries(searchText: "STUDIO").map(\.displayName),
            ["Visual Studio Code"]
        )
    }

    func testLoaderDeduplicatesResolvedApplicationsAndIgnoresOtherFiles() {
        let applicationsRoot = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let userRoot = URL(filePath: "/Users/example/Applications", directoryHint: .isDirectory)
        let visibleApplication = applicationsRoot.appending(path: "Example.app")
        let linkedApplication = userRoot.appending(path: "Example Link.app")
        let resolvedApplication = URL(filePath: "/Users/example/Apps/Example.app")
        let textFile = applicationsRoot.appending(path: "Read Me.txt")
        let eligibility = EligibilityStub(values: [resolvedApplication: .compatible])
        let loader = ApplicationCatalogLoader(
            roots: [applicationsRoot, userRoot],
            eligibility: eligibility,
            directoryContents: { root in
                root == applicationsRoot
                    ? [textFile, visibleApplication]
                    : [linkedApplication]
            },
            resolve: { url in
                url == visibleApplication || url == linkedApplication
                    ? resolvedApplication
                    : url
            },
            displayName: { _ in "Example" }
        )

        let entries = loader.load().entries(searchText: "")

        XCTAssertEqual(entries, [
            ApplicationCatalogEntry(
                url: resolvedApplication,
                displayName: "Example",
                eligibility: .compatible
            ),
        ])
    }

    func testBrowseEntryUsesTheCatalogEligibilityService() {
        let protectedURL = URL(filePath: "/Applications/Protected.app")
        let loader = ApplicationCatalogLoader(
            roots: [],
            eligibility: EligibilityStub(values: [protectedURL: .protected]),
            directoryContents: { _ in [] },
            resolve: { $0 },
            displayName: { _ in "Protected" }
        )

        XCTAssertEqual(
            loader.entry(for: protectedURL),
            ApplicationCatalogEntry(
                url: protectedURL,
                displayName: "Protected",
                eligibility: .protected
            )
        )
    }
}

private struct EligibilityStub: ApplicationEligibilityChecking {
    let values: [URL: ApplicationEligibility]

    func eligibility(for applicationURL: URL) -> ApplicationEligibility {
        values[applicationURL] ?? .invalid
    }
}
