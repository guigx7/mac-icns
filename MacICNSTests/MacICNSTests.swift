import XCTest
@testable import MacICNS

final class MacICNSTests: XCTestCase {
    func testApplicationBootstraps() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.guigx.macicns")
    }

    func testApplicationDeclaresAppManagementUsageDescription() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSAppBundlesUsageDescription") as? String,
            "MacICNS needs permission to apply custom icons to applications you select."
        )
    }

    func testSMAppServiceDaemonDoesNotDeclareLegacyApplicationAssociation() throws {
        let daemonURL = Bundle.main.bundleURL.appending(
            path: "Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist"
        )
        let data = try Data(contentsOf: daemonURL)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertNil(propertyList["AssociatedBundleIdentifiers"])
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

    func testMappingRowExposesChangeIconLabel() {
        XCTAssertEqual(MappingRowPresentation.changeIconLabel, "Change icon")
    }

    @MainActor
    func testInstalledHelperPresentationOffersUpdate() {
        XCTAssertEqual(
            HelperSettingsPresentation.primaryActionTitle(for: .installed),
            "Update Helper"
        )
        XCTAssertEqual(
            HelperSettingsPresentation.primaryActionTitle(for: .updateRequired),
            "Update Helper"
        )
        XCTAssertEqual(
            HelperSettingsPresentation.primaryActionTitle(for: .unavailable),
            "Update Helper"
        )
    }

    @MainActor
    func testAppManagementSettingsActionUsesDedicatedDestination() {
        var openedAppManagementSettings = false
        let service = HelperInstallationService(
            statusProvider: { .installed },
            register: {},
            unregister: {},
            openSettings: {},
            openAppManagementSettings: { openedAppManagementSettings = true }
        )

        service.openAppManagement()

        XCTAssertTrue(openedAppManagementSettings)
    }

    @MainActor
    func testEnabledRegistrationWithMatchingHandshakeIsInstalled() async {
        let service = HelperInstallationService(
            statusProvider: { .installed },
            register: {},
            unregister: {},
            openSettings: {},
            versionProvider: { 2 }
        )

        let status = await service.operationalStatus()
        XCTAssertEqual(status, .installed)
    }

    @MainActor
    func testEnabledRegistrationWithOldHandshakeRequiresUpdate() async {
        let service = HelperInstallationService(
            statusProvider: { .installed },
            register: {},
            unregister: {},
            openSettings: {},
            versionProvider: { 1 }
        )

        let status = await service.operationalStatus()
        XCTAssertEqual(status, .updateRequired)
    }

    @MainActor
    func testEnabledRegistrationWithUnreachableHandshakeIsUnavailable() async {
        let service = HelperInstallationService(
            statusProvider: { .installed },
            register: {},
            unregister: {},
            openSettings: {},
            versionProvider: { throw NSError(domain: "test.helper", code: 1) }
        )

        let status = await service.operationalStatus()
        XCTAssertEqual(status, .unavailable)
    }

    @MainActor
    func testHelperUpdateWaitsForMatchingProtocolVersion() async throws {
        var status = HelperInstallationService.Status.installed
        var versions = [1, 1, 2]
        var checks = 0
        let service = HelperInstallationService(
            statusProvider: { status },
            register: { status = .installed },
            unregister: { status = .notInstalled },
            openSettings: {},
            versionProvider: {
                checks += 1
                return versions.removeFirst()
            },
            readinessRetryLimit: 3,
            readinessRetryDelay: {}
        )

        try await service.update()

        XCTAssertEqual(checks, 3)
    }

    @MainActor
    func testHelperUpdateReportsReadinessExhaustion() async {
        var status = HelperInstallationService.Status.installed
        let service = HelperInstallationService(
            statusProvider: { status },
            register: { status = .installed },
            unregister: { status = .notInstalled },
            openSettings: {},
            versionProvider: { 1 },
            readinessRetryLimit: 2,
            readinessRetryDelay: {}
        )

        do {
            try await service.update()
            XCTFail("Expected helper readiness exhaustion.")
        } catch HelperInstallationService.UpdateError.helperDidNotBecomeReady {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testFailedHelperReadinessDoesNotReapplyMappings() async throws {
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
            unregister: { status = .notInstalled },
            openSettings: {},
            versionProvider: { 1 },
            readinessRetryLimit: 2,
            readinessRetryDelay: {}
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
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(appState.helperStatus, .updateRequired)
        XCTAssertNotNil(appState.helperError)
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
    func testHelperUpdateRetriesTransientRegistrationFailure() async throws {
        var attempts = 0
        var delays = 0
        var status = HelperInstallationService.Status.installed
        let service = HelperInstallationService(
            statusProvider: { status },
            register: {
                attempts += 1
                if attempts < 3 {
                    throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
                }
                status = .installed
            },
            unregister: { status = .notInstalled },
            openSettings: {},
            registrationRetryLimit: 4,
            registrationRetryDelay: { delays += 1 }
        )

        try await service.update()

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, 2)
    }

    @MainActor
    func testHelperUpdateDefaultRetryWindowOutlastsDelayedServiceRelease() async throws {
        var attempts = 0
        var status = HelperInstallationService.Status.installed
        let service = HelperInstallationService(
            statusProvider: { status },
            register: {
                attempts += 1
                if attempts <= 60 {
                    throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
                }
                status = .installed
            },
            unregister: { status = .notInstalled },
            openSettings: {},
            registrationRetryDelay: {}
        )

        try await service.update()

        XCTAssertEqual(attempts, 61)
    }

    @MainActor
    func testHelperUpdateDoesNotRetryUnrelatedRegistrationFailure() async {
        var attempts = 0
        var delays = 0
        let service = HelperInstallationService(
            statusProvider: { .notInstalled },
            register: {
                attempts += 1
                throw HelperUpdateTestError.registrationFailed
            },
            unregister: {},
            openSettings: {},
            registrationRetryLimit: 4,
            registrationRetryDelay: { delays += 1 }
        )

        do {
            try await service.update()
            XCTFail("Expected the unrelated registration failure to propagate.")
        } catch HelperUpdateTestError.registrationFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(delays, 0)
    }

    @MainActor
    func testHelperUpdateReportsApprovalRequirementAfterRetryExhaustion() async {
        var attempts = 0
        var delays = 0
        let service = HelperInstallationService(
            statusProvider: { .notInstalled },
            register: {
                attempts += 1
                throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
            },
            unregister: {},
            openSettings: {},
            registrationRetryLimit: 3,
            registrationRetryDelay: { delays += 1 }
        )

        do {
            try await service.update()
            XCTFail("Expected registration retry exhaustion.")
        } catch HelperInstallationService.UpdateError.requiresApproval {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, 2)
    }

    @MainActor
    func testDeniedHelperUpdateOpensLoginItemsApproval() async {
        var status = HelperInstallationService.Status.installed
        var openedSettings = false
        let service = HelperInstallationService(
            statusProvider: { status },
            register: {
                throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
            },
            unregister: { status = .notInstalled },
            openSettings: { openedSettings = true },
            registrationRetryLimit: 1,
            registrationRetryDelay: {}
        )
        let appState = AppState(
            repository: EmptyMappingRepository(),
            helperInstallationService: service
        )

        await appState.updateHelper()

        XCTAssertEqual(appState.helperStatus, .requiresApproval)
        XCTAssertTrue(openedSettings)
        XCTAssertTrue(appState.helperError?.contains("approval") == true)
    }

    @MainActor
    func testDeniedHelperInstallOpensLoginItemsApproval() async {
        var openedSettings = false
        let service = HelperInstallationService(
            statusProvider: { .notInstalled },
            register: {
                throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
            },
            unregister: {},
            openSettings: { openedSettings = true }
        )
        let appState = AppState(
            repository: EmptyMappingRepository(),
            helperInstallationService: service
        )

        await appState.installHelper()

        XCTAssertEqual(appState.helperStatus, .requiresApproval)
        XCTAssertTrue(openedSettings)
        XCTAssertTrue(appState.helperError?.contains("approval") == true)
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
    func testLaunchSilentlyPersistsOnlySupportedMappings() {
        let compatibleURL = URL(filePath: "/Applications/Compatible.app")
        let protectedURL = URL(filePath: "/Applications/Protected.app")
        let missingURL = URL(filePath: "/Applications/Missing.app")
        var compatible = IconMapping(
            applicationURL: compatibleURL,
            bundleIdentifier: nil,
            iconURL: URL(filePath: "/tmp/Compatible.icns")
        )
        var protected = IconMapping(
            applicationURL: protectedURL,
            bundleIdentifier: nil,
            iconURL: URL(filePath: "/tmp/Protected.icns")
        )
        var missing = IconMapping(
            applicationURL: missingURL,
            bundleIdentifier: nil,
            iconURL: URL(filePath: "/tmp/Missing.icns")
        )
        compatible.isEnabled = false
        protected.isEnabled = false
        missing.isEnabled = false
        let repository = MemoryMappingRepository([compatible, protected, missing])
        let pruner = MappingEligibilityPruner(
            eligibility: AppStateEligibilityStub(values: [
                compatibleURL: .compatible,
                protectedURL: .protected,
                missingURL: .missing,
            ]),
            locator: AppStateLocatorStub(values: [:])
        )
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
            eligibilityPruner: pruner
        )

        appState.loadMappings()

        XCTAssertEqual(appState.mappings.map(\.id), [compatible.id, missing.id])
        XCTAssertEqual(repository.savedMappings.map(\.id), [compatible.id, missing.id])
        XCTAssertEqual(repository.saveCount, 1)
        XCTAssertNil(appState.operationError)
    }

    @MainActor
    func testAddMappingRejectsUnsupportedStaleSelection() async {
        let protectedURL = URL(filePath: "/Applications/Protected.app")
        let repository = MemoryMappingRepository([])
        let pruner = MappingEligibilityPruner(
            eligibility: AppStateEligibilityStub(values: [protectedURL: .protected]),
            locator: AppStateLocatorStub(values: [:])
        )
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
            eligibilityPruner: pruner
        )

        await appState.addMapping(
            applicationURL: protectedURL,
            iconURL: URL(filePath: "/tmp/Protected.icns")
        )

        XCTAssertTrue(appState.mappings.isEmpty)
        XCTAssertEqual(repository.saveCount, 0)
        XCTAssertNil(appState.operationError)
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

    @MainActor
    func testEnabledIconReplacementPersistsAfterApply() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        let repository = MemoryMappingRepository([mapping])
        let applier = IconReplacementApplier()
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                fingerprinting: ConstantFingerprinting(value: "same"),
                applier: applier
            )
        )
        appState.loadMappings()
        try await Task.sleep(for: .milliseconds(50))

        await appState.replaceIcon(for: mapping, with: fixture.replacementIconURL)

        XCTAssertEqual(
            repository.savedMappings.first?.iconURL,
            fixture.replacementIconURL.standardizedFileURL
        )
        let appliedIconURLs = await applier.appliedIconURLs
        XCTAssertEqual(appliedIconURLs, [fixture.replacementIconURL])
    }

    @MainActor
    func testFailedEnabledIconReplacementPreservesPreviousMapping() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                fingerprinting: ConstantFingerprinting(value: "same"),
                applier: IconReplacementApplier(failApply: true)
            )
        )
        appState.loadMappings()
        try await Task.sleep(for: .milliseconds(50))

        await appState.replaceIcon(for: mapping, with: fixture.replacementIconURL)

        XCTAssertEqual(repository.savedMappings.first?.iconURL, mapping.iconURL)
        XCTAssertEqual(appState.mappings.first?.iconURL, mapping.iconURL)
        XCTAssertNotNil(appState.operationError)
    }

    @MainActor
    func testDisabledIconReplacementPersistsWithoutApplying() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.isEnabled = false
        let repository = MemoryMappingRepository([mapping])
        let applier = IconReplacementApplier()
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: applier)
        )
        appState.loadMappings()
        try await Task.sleep(for: .milliseconds(50))

        await appState.replaceIcon(for: mapping, with: fixture.replacementIconURL)

        XCTAssertEqual(
            repository.savedMappings.first?.iconURL,
            fixture.replacementIconURL.standardizedFileURL
        )
        XCTAssertEqual(repository.savedMappings.first?.isEnabled, false)
        let appliedIconURLs = await applier.appliedIconURLs
        XCTAssertEqual(appliedIconURLs, [])
    }
}

private struct EmptyMappingRepository: MappingRepository {
    func load() throws -> [IconMapping] { [] }
    func save(_ mappings: [IconMapping]) throws {}
}

private struct AppStateEligibilityStub: ApplicationEligibilityChecking {
    let values: [URL: ApplicationEligibility]

    func eligibility(for applicationURL: URL) -> ApplicationEligibility {
        values[applicationURL] ?? .invalid
    }
}

private struct AppStateLocatorStub: ApplicationLocating {
    let values: [String: URL]

    func resolve(_ bundleIdentifier: String) -> URL? {
        values[bundleIdentifier]
    }
}

private final class MemoryMappingRepository: MappingRepository, @unchecked Sendable {
    private var loadedMappings: [IconMapping]
    private(set) var savedMappings: [IconMapping]
    private(set) var saveCount = 0

    init(_ mappings: [IconMapping]) {
        loadedMappings = mappings
        savedMappings = mappings
    }

    func load() throws -> [IconMapping] { loadedMappings }

    func save(_ mappings: [IconMapping]) throws {
        saveCount += 1
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

private actor IconReplacementApplier: IconApplying {
    private(set) var appliedIconURLs: [URL] = []
    private let failApply: Bool

    init(failApply: Bool = false) {
        self.failApply = failApply
    }

    func apply(applicationURL: URL, iconURL: URL) async throws {
        if failApply {
            throw CocoaError(.fileWriteUnknown)
        }
        appliedIconURLs.append(iconURL)
    }

    func reset(applicationURL: URL) async throws {}
}

private enum HelperUpdateTestError: Error {
    case registrationFailed
    case unregisterFailed
}

private struct MappingFixture {
    let directory: URL
    let mapping: IconMapping
    let replacementIconURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let applicationURL = directory.appending(path: "Example.app", directoryHint: .isDirectory)
        let iconURL = directory.appending(path: "Example.icns")
        replacementIconURL = directory.appending(path: "Replacement.icns")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: iconURL)
        try Data("replacement".utf8).write(to: replacementIconURL)
        mapping = IconMapping(applicationURL: applicationURL, bundleIdentifier: nil, iconURL: iconURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
