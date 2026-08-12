import XCTest
@testable import MacICNS

final class MacICNSTests: XCTestCase {
    func testApplicationBootstraps() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.guigx.macicns")
    }

    func testApplicationDoesNotDeclareAppManagementUsage() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSAppBundlesUsageDescription"))
    }

    func testBuiltApplicationContainsNoPrivilegedHelper() {
        let root = Bundle.main.bundleURL
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appending(path: "Contents/Library/LaunchServices/com.guigx.macicns.helper").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appending(path: "Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist").path))
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

    func testRefreshIconsUsesTheSharedEnglishLabel() {
        XCTAssertEqual(MappingListPresentation.refreshIconsLabel, "Refresh Icons")
    }

    func testRestartRequiredPresentationUsesEnglishGuidance() {
        var mapping = IconMapping(
            applicationURL: URL(filePath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.App",
            iconURL: URL(filePath: "/tmp/Example.icns")
        )
        mapping.status = .restartRequired

        XCTAssertEqual(MappingRowPresentation.statusName(for: mapping), "Restart required")
        XCTAssertEqual(
            MappingRowPresentation.statusMessage(for: mapping, failureMessage: nil),
            "Quit and reopen this app to refresh its Dock icon."
        )
        XCTAssertTrue(MappingRowPresentation.isAttentionStatus(mapping))
    }

    func testDisabledMappingHidesRestartGuidance() {
        var mapping = IconMapping(
            applicationURL: URL(filePath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.App",
            iconURL: URL(filePath: "/tmp/Example.icns")
        )
        mapping.status = .restartRequired
        mapping.isEnabled = false

        XCTAssertEqual(MappingRowPresentation.statusName(for: mapping), "Disabled")
        XCTAssertNil(MappingRowPresentation.statusMessage(for: mapping, failureMessage: nil))
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
    func testTargetTerminationClearsRestartRequiredWhenNoProcessRemains() async throws {
        let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.status = .restartRequired
        let repository = MemoryMappingRepository([mapping])
        let runningChecker = MutableRunningChecker(values: ["com.example.Target": false])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                applicationRunningChecker: runningChecker,
                applier: LifecycleApplier()
            ),
            applicationRunningChecker: runningChecker,
            applicationTerminationObserver: NoopTerminationObserver()
        )
        appState.loadMappings()

        await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")

        XCTAssertEqual(appState.mappings.first?.status, .upToDate)
        XCTAssertEqual(repository.savedMappings.first?.status, .upToDate)
    }

    @MainActor
    func testTerminationReconcilesMonitorSnapshotBeforeLaterFilesystemRepair() async throws {
        let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        mapping.status = .restartRequired
        let repository = MemoryMappingRepository([mapping])
        let runningChecker = MutableRunningChecker(values: ["com.example.Target": true])
        let streamFactory = AppStateMappingEventStreamFactory()
        let coordinator = RepairCoordinator(
            fingerprinting: ConstantFingerprinting(value: "same"),
            applicationRunningChecker: runningChecker,
            applier: LifecycleApplier()
        )
        let appState = AppState(
            repository: repository,
            repairCoordinator: coordinator,
            applicationRunningChecker: runningChecker,
            applicationTerminationObserver: NoopTerminationObserver(),
            mappingFileMonitorFactory: { coordinator, onRepair in
                MappingFileMonitor(
                    repairCoordinator: coordinator,
                    onRepair: onRepair,
                    streamFactory: streamFactory.make,
                    schedulerFactory: { repair, completion in
                        RepairScheduler(
                            delay: .zero,
                            clock: ImmediateRepairSchedulingClock(),
                            repair: repair,
                            repairCompletion: completion
                        )
                    }
                )
            }
        )
        appState.loadMappings()
        await appState.apply(mapping)

        await runningChecker.setRunning(false, bundleIdentifier: "com.example.Target")
        await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")
        XCTAssertEqual(appState.mappings.first?.status, .upToDate)

        await runningChecker.setRunning(true, bundleIdentifier: "com.example.Target")
        let filesystemRepairSaved = expectation(description: "filesystem repair persisted")
        repository.notifyOnNextSave {
            filesystemRepairSaved.fulfill()
        }
        let stream = try XCTUnwrap(streamFactory.latestStream)
        stream.emit(paths: [mapping.applicationURL.path])
        await fulfillment(of: [filesystemRepairSaved], timeout: 1)

        XCTAssertEqual(appState.mappings.first?.status, .upToDate)
        XCTAssertEqual(repository.savedMappings.first?.status, .upToDate)
    }

    @MainActor
    func testTargetTerminationKeepsRestartRequiredWhileAnotherProcessRuns() async throws {
        let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.status = .restartRequired
        let runningChecker = MutableRunningChecker(values: ["com.example.Target": true])
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                applicationRunningChecker: runningChecker,
                applier: LifecycleApplier()
            ),
            applicationRunningChecker: runningChecker,
            applicationTerminationObserver: NoopTerminationObserver()
        )
        appState.loadMappings()
        try await Task.sleep(for: .milliseconds(50))
        let saveCount = repository.saveCount

        await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")

        XCTAssertEqual(appState.mappings.first?.status, .restartRequired)
        XCTAssertEqual(repository.saveCount, saveCount)
    }

    @MainActor
    func testUnrelatedTerminationDoesNotChangeRestartRequiredMapping() async throws {
        let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.status = .restartRequired
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
            applicationRunningChecker: MutableRunningChecker(values: [:]),
            applicationTerminationObserver: NoopTerminationObserver()
        )
        appState.loadMappings()
        let saveCount = repository.saveCount

        await appState.applicationDidTerminate(bundleIdentifier: "com.example.Other")

        XCTAssertEqual(appState.mappings.first?.status, .restartRequired)
        XCTAssertEqual(repository.saveCount, saveCount)
    }

    @MainActor
    func testTerminationRevalidatesMappingIdentitiesAfterInterleavedDeletion() async throws {
        let targetFixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        let unrelatedFixture = try MappingFixture(bundleIdentifier: "com.example.Other")
        defer {
            targetFixture.remove()
            unrelatedFixture.remove()
        }
        var target = targetFixture.mapping
        target.status = .restartRequired
        var unrelated = unrelatedFixture.mapping
        unrelated.status = .restartRequired
        let repository = MemoryMappingRepository([target, unrelated])
        let runningChecker = BlockingRunningChecker()
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                fingerprinting: ConstantFingerprinting(value: "same"),
                applicationRunningChecker: ConstantRunningChecker(isRunning: true),
                applier: LifecycleApplier()
            ),
            applicationRunningChecker: runningChecker,
            applicationTerminationObserver: NoopTerminationObserver()
        )
        appState.loadMappings()

        let termination = Task {
            await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")
        }
        await runningChecker.waitUntilCheckStarts()
        await appState.delete(target)
        await runningChecker.finish(isRunning: false)
        await termination.value

        XCTAssertEqual(appState.mappings.map(\.id), [unrelated.id])
        XCTAssertEqual(appState.mappings.first?.status, .restartRequired)
        XCTAssertEqual(repository.savedMappings.map(\.id), [unrelated.id])
        XCTAssertEqual(repository.savedMappings.first?.status, .restartRequired)
    }

    @MainActor
    func testTerminationDoesNotOverwriteInterleavedSameIDIconReplacement() async throws {
        let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        mapping.status = .restartRequired
        let repository = MemoryMappingRepository([mapping])
        let terminationChecker = BlockingRunningChecker()
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                fingerprinting: ConstantFingerprinting(value: "same"),
                applicationRunningChecker: ConstantRunningChecker(isRunning: true),
                applier: IconReplacementApplier()
            ),
            applicationRunningChecker: terminationChecker,
            applicationTerminationObserver: NoopTerminationObserver()
        )
        appState.loadMappings()
        await appState.apply(mapping)
        let currentMapping = try XCTUnwrap(appState.mappings.first)

        let termination = Task {
            await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")
        }
        await terminationChecker.waitUntilCheckStarts()
        await appState.replaceIcon(for: currentMapping, with: fixture.replacementIconURL)
        await terminationChecker.finish(isRunning: false)
        await termination.value

        XCTAssertEqual(
            appState.mappings.first?.iconURL,
            fixture.replacementIconURL.standardizedFileURL
        )
        XCTAssertEqual(appState.mappings.first?.status, .restartRequired)
        XCTAssertEqual(repository.savedMappings.first?.status, .restartRequired)
    }

    @MainActor
    func testDisabledTargetTerminationDoesNotChangeRestartRequiredMapping() async throws {
        let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.isEnabled = false
        mapping.status = .restartRequired
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
            applicationRunningChecker: MutableRunningChecker(values: [:]),
            applicationTerminationObserver: NoopTerminationObserver()
        )
        appState.loadMappings()
        let saveCount = repository.saveCount

        await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")

        XCTAssertEqual(appState.mappings.first?.status, .restartRequired)
        XCTAssertEqual(repository.saveCount, saveCount)
    }

    @MainActor
    func testTargetTerminationDoesNotChangeNonRestartRequiredMapping() async throws {
        let fixture = try MappingFixture(bundleIdentifier: "com.example.Target")
        defer { fixture.remove() }
        let mapping = fixture.mapping
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
            applicationRunningChecker: MutableRunningChecker(values: [:]),
            applicationTerminationObserver: NoopTerminationObserver()
        )
        appState.loadMappings()
        let saveCount = repository.saveCount

        await appState.applicationDidTerminate(bundleIdentifier: "com.example.Target")

        XCTAssertEqual(appState.mappings.first?.status, .upToDate)
        XCTAssertEqual(repository.saveCount, saveCount)
    }

    @MainActor
    func testLaunchingTwiceStartsTerminationObservationOnce() {
        let observer = RecordingTerminationObserver()
        let appState = AppState(
            repository: EmptyMappingRepository(),
            applicationTerminationObserver: observer
        )

        appState.launch()
        appState.launch()

        XCTAssertEqual(observer.startCount, 1)
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
    func testEnabledIconReplacementPersistsWhenRunningAppRequiresRestart() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.bundleIdentifier = "com.example.Target"
        let repository = MemoryMappingRepository([mapping])
        let runningChecker = ConstantRunningChecker(isRunning: true)
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                fingerprinting: ConstantFingerprinting(value: "new"),
                applicationRunningChecker: runningChecker,
                applier: IconReplacementApplier()
            )
        )
        appState.loadMappings()
        try await Task.sleep(for: .milliseconds(50))

        await appState.replaceIcon(for: mapping, with: fixture.replacementIconURL)

        XCTAssertEqual(
            repository.savedMappings.first?.iconURL,
            fixture.replacementIconURL.standardizedFileURL
        )
        XCTAssertEqual(repository.savedMappings.first?.status, .restartRequired)
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

    @MainActor
    func testManualRefreshReappliesMappingsThenReloadsDockOnce() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        let repository = MemoryMappingRepository([fixture.mapping])
        let applier = LifecycleApplier()
        let reloader = RecordingDockReloader()
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: applier),
            dockReloader: reloader
        )
        appState.loadMappings()

        await appState.refreshAll()

        let reloadCount = await reloader.reloadsPerformed()
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(repository.savedMappings.count, 1)
    }

    @MainActor
    func testManualRefreshReloadsDockWhenAMappingRepairFails() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        let repository = MemoryMappingRepository([fixture.mapping])
        let reloader = RecordingDockReloader()
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: FailingApplyLifecycleApplier()),
            dockReloader: reloader
        )
        appState.loadMappings()

        await appState.refreshAll()

        let reloadCount = await reloader.reloadsPerformed()
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(repository.savedMappings.first?.status, .failed)
    }

    @MainActor
    func testDockReloadFailurePreservesRefreshResultsAndShowsOperationError() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        let repository = MemoryMappingRepository([fixture.mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
            dockReloader: FailingDockReloader()
        )
        appState.loadMappings()

        await appState.refreshAll()

        XCTAssertEqual(repository.savedMappings.first?.status, .upToDate)
        XCTAssertEqual(appState.operationError, "Could not reload the Dock.")
    }

    @MainActor
    func testManualRefreshDoesNotStartSecondDockReloadWhileFirstIsRunning() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        let repository = MemoryMappingRepository([fixture.mapping])
        let reloader = BlockingDockReloader()
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(applier: LifecycleApplier()),
            dockReloader: reloader
        )
        appState.loadMappings()

        let firstRefresh = Task { await appState.refreshAll() }
        await reloader.waitUntilReloadStarts()

        XCTAssertTrue(appState.isRefreshingAll)
        await appState.refreshAll()
        let reloadCount = await reloader.reloadsPerformed()
        XCTAssertEqual(reloadCount, 1)

        await reloader.finishReload()
        await firstRefresh.value
        XCTAssertFalse(appState.isRefreshingAll)
    }

    @MainActor
    func testManualRefreshSkipsDockReloadWhenAnotherMappingOperationIsBusy() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        let applier = BlockingLifecycleApplier()
        let reloader = RecordingDockReloader()
        let appState = AppState(
            repository: MemoryMappingRepository([mapping]),
            repairCoordinator: RepairCoordinator(
                fingerprinting: ConstantFingerprinting(value: "same"),
                applier: applier
            ),
            dockReloader: reloader
        )
        appState.loadMappings()

        let applyTask = Task { await appState.apply(mapping) }
        await applier.waitUntilApplyStarts()

        await appState.refreshAll()

        let reloadCount = await reloader.reloadsPerformed()
        XCTAssertEqual(reloadCount, 0)

        await applier.finishApply()
        await applyTask.value
    }

    @MainActor
    func testManualRefreshSkipsDockReloadWhenRepairResultIsStale() async throws {
        let fixture = try MappingFixture()
        defer { fixture.remove() }
        var mapping = fixture.mapping
        mapping.appFingerprint = "same"
        mapping.iconFingerprint = "same"
        let applier = BlockingLifecycleApplier()
        let reloader = RecordingDockReloader()
        let repository = MemoryMappingRepository([mapping])
        let appState = AppState(
            repository: repository,
            repairCoordinator: RepairCoordinator(
                fingerprinting: ConstantFingerprinting(value: "same"),
                applier: applier
            ),
            dockReloader: reloader
        )
        appState.loadMappings()

        let refreshTask = Task { await appState.refreshAll() }
        await applier.waitUntilApplyStarts()
        appState.loadMappings()
        await applier.finishApply()
        await refreshTask.value

        let reloadCount = await reloader.reloadsPerformed()
        XCTAssertEqual(reloadCount, 0)
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
    private var nextSaveHandler: (() -> Void)?

    init(_ mappings: [IconMapping]) {
        loadedMappings = mappings
        savedMappings = mappings
    }

    func load() throws -> [IconMapping] { loadedMappings }

    func save(_ mappings: [IconMapping]) throws {
        saveCount += 1
        savedMappings = mappings
        loadedMappings = mappings
        let handler = nextSaveHandler
        nextSaveHandler = nil
        handler?()
    }

    func notifyOnNextSave(_ handler: @escaping () -> Void) {
        nextSaveHandler = handler
    }
}

private struct ImmediateRepairSchedulingClock: RepairSchedulingClock {
    func sleep(for _: Duration) async throws {}
}

@MainActor
private final class AppStateMappingEventStreamFactory {
    private(set) var latestStream: AppStateMappingEventStream?

    func make(
        directories _: Set<String>,
        handler: @escaping @Sendable ([String]) -> Void
    ) -> any MappingEventStream {
        let stream = AppStateMappingEventStream(handler: handler)
        latestStream = stream
        return stream
    }
}

@MainActor
private final class AppStateMappingEventStream: MappingEventStream {
    private let handler: @Sendable ([String]) -> Void

    init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }

    func start() {}

    func stop() {}

    func emit(paths: [String]) {
        handler(paths)
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

private actor FailingApplyLifecycleApplier: IconApplying {
    func apply(applicationURL _: URL, iconURL _: URL) async throws {
        throw CocoaError(.fileWriteUnknown)
    }

    func reset(applicationURL _: URL) async throws {}
}

private actor RecordingDockReloader: DockReloading {
    private(set) var reloadCount = 0

    func reload() async throws {
        reloadCount += 1
    }

    func reloadsPerformed() -> Int {
        reloadCount
    }
}

private struct FailingDockReloader: DockReloading {
    func reload() async throws {
        throw DockReloadError.launchFailed
    }
}

private actor BlockingDockReloader: DockReloading {
    private var didStart = false
    private var reloadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var reloadCount = 0

    func reload() async throws {
        reloadCount += 1
        didStart = true
        reloadStartWaiters.forEach { $0.resume() }
        reloadStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilReloadStarts() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            reloadStartWaiters.append(continuation)
        }
    }

    func finishReload() {
        continuation?.resume()
        continuation = nil
    }

    func reloadsPerformed() -> Int {
        reloadCount
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

private struct ConstantRunningChecker: ApplicationRunningChecking {
    let runningValue: Bool

    init(isRunning: Bool) {
        runningValue = isRunning
    }

    func isRunning(bundleIdentifier: String) async -> Bool {
        runningValue
    }
}

private actor MutableRunningChecker: ApplicationRunningChecking {
    private var values: [String: Bool]

    init(values: [String: Bool]) {
        self.values = values
    }

    func isRunning(bundleIdentifier: String) async -> Bool {
        values[bundleIdentifier] ?? false
    }

    func setRunning(_ isRunning: Bool, bundleIdentifier: String) {
        values[bundleIdentifier] = isRunning
    }
}

private actor BlockingRunningChecker: ApplicationRunningChecking {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Bool, Never>?

    func isRunning(bundleIdentifier _: String) async -> Bool {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilCheckStarts() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(isRunning: Bool) {
        continuation?.resume(returning: isRunning)
        continuation = nil
    }
}

@MainActor
private final class NoopTerminationObserver: ApplicationTerminationObserving {
    func startObservingTerminations(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {}

    func stopObservingTerminations() {}
}

@MainActor
private final class RecordingTerminationObserver: ApplicationTerminationObserving {
    private(set) var startCount = 0

    func startObservingTerminations(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        startCount += 1
    }

    func stopObservingTerminations() {}
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


private struct MappingFixture {
    let directory: URL
    let mapping: IconMapping
    let replacementIconURL: URL

    init(bundleIdentifier: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let applicationURL = directory.appending(path: "Example.app", directoryHint: .isDirectory)
        let iconURL = directory.appending(path: "Example.icns")
        replacementIconURL = directory.appending(path: "Replacement.icns")
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: iconURL)
        try Data("replacement".utf8).write(to: replacementIconURL)
        mapping = IconMapping(
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            iconURL: iconURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
