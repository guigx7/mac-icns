import XCTest
@testable import MacICNS

final class MacICNSTests: XCTestCase {
    func testApplicationBootstraps() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.guigx.macicns")
    }

    func testFileSelectionValidatorAcceptsOnlyExpectedExtensions() {
        XCTAssertTrue(FileSelectionValidator.isApplication(URL(filePath: "/Applications/Example.app")))
        XCTAssertFalse(FileSelectionValidator.isApplication(URL(filePath: "/Applications/Example.icns")))
        XCTAssertTrue(FileSelectionValidator.isIcon(URL(filePath: "/tmp/Icon.icns")))
        XCTAssertFalse(FileSelectionValidator.isIcon(URL(filePath: "/tmp/Icon.png")))
    }

    func testMappingToggleLabelReflectsPersistedEnabledState() {
        XCTAssertEqual(MappingRowPresentation.toggleLabel(isEnabled: true), "Enabled")
        XCTAssertEqual(MappingRowPresentation.toggleLabel(isEnabled: false), "Disabled")
    }

    @MainActor
    func testInstalledHelperPresentationOffersUpdate() {
        XCTAssertEqual(
            HelperSettingsPresentation.primaryActionTitle(for: .installed),
            "Update Helper"
        )
    }

    @MainActor
    func testHelperUpdateUnregistersBeforeRegistering() async throws {
        var events: [String] = []
        var status = HelperInstallationService.Status.installed
        let service = HelperInstallationService(
            statusProvider: { status },
            register: {
                events.append("register")
                status = .installed
            },
            unregister: {
                await Task.yield()
                events.append("unregister")
                status = .notInstalled
            },
            openSettings: {}
        )

        try await service.update()

        XCTAssertEqual(events, ["unregister", "register"])
        XCTAssertEqual(service.status, .installed)
    }

    @MainActor
    func testHelperUpdateWaitsUntilServiceManagementReportsRemoval() async throws {
        var statusReads = 0
        var didRegister = false
        let service = HelperInstallationService(
            statusProvider: {
                statusReads += 1
                return statusReads >= 3 ? .notInstalled : .installed
            },
            register: {
                guard statusReads >= 3 else {
                    throw HelperUpdateTestError.serviceStillRegistered
                }
                didRegister = true
            },
            unregister: {},
            openSettings: {}
        )

        try await service.update()

        XCTAssertTrue(didRegister)
        XCTAssertGreaterThanOrEqual(statusReads, 3)
    }

    @MainActor
    func testHelperUpdateFailureRemainsVisible() async {
        let service = HelperInstallationService(
            statusProvider: { .installed },
            register: {},
            unregister: {
                await Task.yield()
                throw HelperUpdateTestError.unregisterFailed
            },
            openSettings: {}
        )
        let appState = AppState(
            repository: EmptyMappingRepository(),
            helperInstallationService: service
        )

        await appState.updateHelper()

        XCTAssertEqual(appState.helperStatus, .installed)
        XCTAssertFalse(appState.helperIsUpdating)
        XCTAssertTrue(appState.helperError?.contains("Could not update the helper") == true)
    }

    @MainActor
    func testSuccessfulHelperUpdateReappliesEnabledMappings() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        let applier = UpdateRecordingApplier()
        let coordinator = RepairCoordinator(
            fingerprinting: ConstantFingerprinting(value: "same"),
            applier: applier
        )
        var status = HelperInstallationService.Status.installed
        let service = HelperInstallationService(
            statusProvider: { status },
            register: { status = .installed },
            unregister: {
                await Task.yield()
                status = .notInstalled
            },
            openSettings: {}
        )
        let appState = AppState(
            repository: MemoryMappingRepository([mapping]),
            repairCoordinator: coordinator,
            helperInstallationService: service
        )
        appState.loadMappings()
        try await Task.sleep(for: .milliseconds(50))

        await appState.updateHelper()

        let applyCount = await applier.applyCount
        XCTAssertEqual(applyCount, 1)
        XCTAssertEqual(appState.helperStatus, .installed)
        XCTAssertNil(appState.helperError)
    }

    func testFSEventPathDecoderReadsCStringVector() {
        let first = strdup("/Applications/Spotify.app")!
        let second = strdup("/Applications/Spotify.app/Contents/Info.plist")!
        defer {
            free(first)
            free(second)
        }
        var pointers: [UnsafePointer<CChar>?] = [
            UnsafePointer(first),
            UnsafePointer(second),
        ]

        let pointerCount = pointers.count
        let decoded = pointers.withUnsafeMutableBytes { bytes in
            FSEventPathDecoder.decode(bytes.baseAddress!, count: pointerCount)
        }

        XCTAssertEqual(decoded, [
            "/Applications/Spotify.app",
            "/Applications/Spotify.app/Contents/Info.plist",
        ])
    }

    @MainActor
    func testLaunchingTwiceInitializesOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let logURL = directory.appending(path: "diagnostics.log")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(fileURL: logURL)
        let appState = AppState(
            repository: EmptyMappingRepository(),
            diagnosticLogger: logger
        )

        appState.launch()
        appState.launch()

        let loadedEntries = try logger.copyableContents()
            .split(separator: "\n")
            .filter { $0.contains("Loaded 0 icon mappings.") }
        XCTAssertEqual(loadedEntries.count, 1)
    }

    @MainActor
    func testDeletingRestoresThenPersistsRemoval() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.isEnabled = false
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier())
        )
        appState.loadMappings()

        await appState.delete(mapping)

        XCTAssertEqual(repository.savedMappings, [])
        XCTAssertEqual(appState.mappings, [])
    }

    @MainActor
    func testFailedDeleteKeepsPersistedMapping() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.isEnabled = false
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier(failReset: true))
        )
        appState.loadMappings()

        await appState.delete(mapping)

        XCTAssertEqual(repository.savedMappings.map(\.id), [mapping.id])
        XCTAssertEqual(appState.mappings.map(\.id), [mapping.id])
        XCTAssertNotNil(appState.operationError)
    }

    @MainActor
    func testFailedTogglePreservesPersistedEnabledState() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        let mapping = fixture.mapping
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier(failReset: true))
        )
        appState.loadMappings()

        await appState.setEnabled(false, for: mapping)

        XCTAssertEqual(repository.savedMappings.first?.isEnabled, true)
        XCTAssertEqual(appState.mappings.first?.isEnabled, true)
        XCTAssertNotNil(appState.operationError)
    }

    @MainActor
    func testManualApplyPublishesBusyStateUntilOperationCompletes() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        let mapping = fixture.mapping
        let applier = BlockingLifecycleApplier()
        let appState = AppState(
            repository: MemoryMappingRepository([mapping]),
            repairCoordinator: RepairCoordinator(applier: applier)
        )
        appState.loadMappings()

        let applyTask = Task { await appState.apply(mapping) }
        await applier.waitUntilApplyStarts()

        XCTAssertTrue(appState.isBusy(mapping))
        await applier.finishApply()
        await applyTask.value
        XCTAssertFalse(appState.isBusy(mapping))
    }
}

private struct EmptyMappingRepository: MappingRepository {
    func load() throws -> [IconMapping] { [] }
    func save(_ mappings: [IconMapping]) throws {}
}

private final class MemoryMappingRepository: MappingRepository, @unchecked Sendable {
    private var loadedMappings: [IconMapping]
    private(set) var savedMappings: [IconMapping]

    init(_ mappings: [IconMapping]) {
        loadedMappings = mappings
        savedMappings = mappings
    }

    func load() throws -> [IconMapping] { loadedMappings }

    func save(_ mappings: [IconMapping]) throws {
        savedMappings = mappings
        loadedMappings = mappings
    }
}

private actor LifecycleApplier: IconApplying {
    let failReset: Bool

    init(failReset: Bool = false) {
        self.failReset = failReset
    }

    func apply(applicationURL _: URL, iconURL _: URL) async throws {}

    func reset(applicationURL _: URL) async throws {
        if failReset {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

private actor BlockingLifecycleApplier: IconApplying {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var applyContinuation: CheckedContinuation<Void, Never>?

    func apply(applicationURL _: URL, iconURL _: URL) async throws {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            applyContinuation = continuation
        }
    }

    func reset(applicationURL _: URL) async throws {}

    func waitUntilApplyStarts() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishApply() {
        applyContinuation?.resume()
        applyContinuation = nil
    }
}

private struct ConstantFingerprinting: Fingerprinting {
    let value: String

    func fingerprint(of url: URL) throws -> String { value }
}

private actor UpdateRecordingApplier: IconApplying {
    private(set) var applyCount = 0

    func apply(applicationURL: URL, iconURL: URL) async throws {
        applyCount += 1
    }

    func reset(applicationURL: URL) async throws {}
}

private enum HelperUpdateTestError: Error {
    case serviceStillRegistered
    case unregisterFailed
}

private struct MappingFixture {
    let directory: URL
    let mapping: IconMapping

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let applicationURL = directory.appending(path: "Example.app", directoryHint: .isDirectory)
        let iconURL = directory.appending(path: "Example.icns")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: iconURL)
        mapping = IconMapping(applicationURL: applicationURL, bundleIdentifier: nil, iconURL: iconURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
