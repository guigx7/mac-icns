import Foundation
import XCTest
@testable import MacICNS

final class RepairCoordinatorTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var applicationURL: URL!
    private var iconURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        applicationURL = temporaryDirectory.appending(path: "Test.app", directoryHint: .isDirectory)
        iconURL = temporaryDirectory.appending(path: "Test.icns")

        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: iconURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        applicationURL = nil
        iconURL = nil
    }

    func testRepairSkipsUnchangedMapping() async throws {
        var mapping = makeMapping()
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        mapping.status = .failed

        let applier = RecordingApplier()
        let coordinator = RepairCoordinator(
            fingerprinting: StubFingerprinting(value: "same"),
            locator: StubLocator(),
            applier: applier
        )

        let repaired = await coordinator.repair(mapping, reason: .manual)

        let requests = await applier.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(repaired.status, .upToDate)
    }

    func testRepairAppliesChangedFingerprints() async throws {
        var mapping = makeMapping()
        mapping.appFingerprint = "old-app"
        mapping.iconFingerprint = "old-icon"
        let applier = RecordingApplier()
        let coordinator = RepairCoordinator(
            fingerprinting: StubFingerprinting(values: [applicationURL: "new-app", iconURL: "new-icon"]),
            locator: StubLocator(),
            applier: applier
        )

        let repaired = await coordinator.repair(mapping, reason: .fileSystemChange)

        let requests = await applier.requests
        XCTAssertEqual(requests, [.init(applicationURL: applicationURL, iconURL: iconURL)])
        XCTAssertEqual(repaired.appFingerprint, "new-app")
        XCTAssertEqual(repaired.iconFingerprint, "new-icon")
        XCTAssertNotNil(repaired.lastSuccessAt)
        XCTAssertEqual(repaired.status, .upToDate)
    }

    func testRepairMarksMissingAppWhenLocatorCannotResolve() async throws {
        let mapping = IconMapping(
            applicationURL: temporaryDirectory.appending(path: "Missing.app", directoryHint: .isDirectory),
            bundleIdentifier: "com.example.Missing",
            iconURL: iconURL
        )
        let applier = RecordingApplier()
        let coordinator = RepairCoordinator(
            fingerprinting: StubFingerprinting(value: "new"),
            locator: StubLocator(),
            applier: applier
        )

        let repaired = await coordinator.repair(mapping, reason: .launch)

        XCTAssertEqual(repaired.status, .missingApp)
        let requests = await applier.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRepairUsesResolvedBundleIdentifierURL() async throws {
        let recoveredURL = temporaryDirectory.appending(path: "Recovered.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recoveredURL, withIntermediateDirectories: true)
        let mapping = IconMapping(
            applicationURL: temporaryDirectory.appending(path: "Old.app", directoryHint: .isDirectory),
            bundleIdentifier: "com.example.Test",
            iconURL: iconURL
        )
        let applier = RecordingApplier()
        let coordinator = RepairCoordinator(
            fingerprinting: StubFingerprinting(values: [recoveredURL: "new-app", iconURL: "new-icon"]),
            locator: StubLocator(result: recoveredURL),
            applier: applier
        )

        let repaired = await coordinator.repair(mapping, reason: .launch)

        XCTAssertEqual(repaired.applicationURL, recoveredURL.standardizedFileURL)
        let requests = await applier.requests
        XCTAssertEqual(requests, [.init(applicationURL: recoveredURL, iconURL: iconURL)])
        XCTAssertEqual(repaired.status, .upToDate)
    }

    func testRepairMarksPermissionFailure() async throws {
        var mapping = makeMapping()
        mapping.appFingerprint = "old-app"
        mapping.iconFingerprint = "old-icon"
        let coordinator = RepairCoordinator(
            fingerprinting: StubFingerprinting(value: "new"),
            locator: StubLocator(),
            applier: ErrorApplier(error: CocoaError(.fileWriteNoPermission))
        )

        let repaired = await coordinator.repair(mapping, reason: .manual)

        XCTAssertEqual(repaired.status, .needsPermission)
        XCTAssertNil(repaired.lastSuccessAt)
    }

    func testRepairMarksNonPermissionFailureAsFailed() async throws {
        var mapping = makeMapping()
        mapping.appFingerprint = "old-app"
        mapping.iconFingerprint = "old-icon"
        let coordinator = RepairCoordinator(
            fingerprinting: StubFingerprinting(value: "new"),
            locator: StubLocator(),
            applier: ErrorApplier(error: TestError.other)
        )

        let repaired = await coordinator.repair(mapping, reason: .manual)

        XCTAssertEqual(repaired.status, .failed)
    }

    func testRepairCoalescesSimultaneousRequestsForSameMapping() async throws {
        var mapping = makeMapping()
        mapping.appFingerprint = "old-app"
        mapping.iconFingerprint = "old-icon"
        let applier = DelayingApplier()
        let coordinator = RepairCoordinator(
            fingerprinting: StubFingerprinting(value: "new"),
            locator: StubLocator(),
            applier: applier
        )
        let firstMapping = mapping
        let secondMapping = mapping

        async let firstRepair = coordinator.repair(firstMapping, reason: .fileSystemChange)
        async let secondRepair = coordinator.repair(secondMapping, reason: .fileSystemChange)
        let (firstResult, secondResult) = await (firstRepair, secondRepair)

        XCTAssertEqual(firstResult.status, .upToDate)
        XCTAssertEqual(secondResult.status, .upToDate)
        let requestCount = await applier.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    private func makeMapping() -> IconMapping {
        IconMapping(
            applicationURL: applicationURL,
            bundleIdentifier: "com.example.Test",
            iconURL: iconURL
        )
    }
}

private struct StubFingerprinting: Fingerprinting {
    let defaultValue: String
    let values: [URL: String]

    init(value: String) {
        defaultValue = value
        values = [:]
    }

    init(values: [URL: String]) {
        defaultValue = "default"
        self.values = values
    }

    func fingerprint(of url: URL) throws -> String {
        values[url] ?? defaultValue
    }
}

private struct StubLocator: ApplicationLocating {
    let result: URL?

    init(result: URL? = nil) {
        self.result = result
    }

    func resolve(_ bundleIdentifier: String) -> URL? {
        result
    }
}

private struct ErrorApplier: IconApplying {
    let error: any Error

    func apply(applicationURL: URL, iconURL: URL) async throws {
        throw error
    }
}

private enum TestError: Error, Sendable {
    case other
}

private actor DelayingApplier: IconApplying {
    private(set) var requestCount = 0

    func apply(applicationURL: URL, iconURL: URL) async throws {
        requestCount += 1
        try await Task.sleep(for: .milliseconds(50))
    }
}

private actor RecordingApplier: IconApplying {
    struct Request: Equatable {
        let applicationURL: URL
        let iconURL: URL
    }

    private(set) var requests: [Request] = []

    func apply(applicationURL: URL, iconURL: URL) async throws {
        requests.append(Request(applicationURL: applicationURL, iconURL: iconURL))
    }
}
