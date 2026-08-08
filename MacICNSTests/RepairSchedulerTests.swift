import Foundation
import XCTest
@testable import MacICNS

final class RepairSchedulerTests: XCTestCase {
    func testMultipleEventsScheduleOneRepairThreeSecondsAfterLatestEvent() async {
        let clock = TestClock()
        let recorder = RepairRecorder()
        let mappingID = UUID()
        let scheduler = RepairScheduler(delay: .seconds(3), clock: clock) { id, _ in
            await recorder.record(id)
        }

        await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
        let firstSleepStarted = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(firstSleepStarted)
        await clock.advance(by: .seconds(2))
        await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
        let secondSleepStarted = await clock.waitUntilSleepRequested(count: 2)
        XCTAssertTrue(secondSleepStarted)
        await clock.advance(by: .seconds(1))
        let IDsBeforeDeadline = await recorder.ids
        XCTAssertTrue(IDsBeforeDeadline.isEmpty)
        await clock.advance(by: .seconds(2))
        await recorder.waitForCount(1)

        let recordedIDs = await recorder.ids
        XCTAssertEqual(recordedIDs, [mappingID])
        let requestedDurations = await clock.requestedDurations
        XCTAssertEqual(requestedDurations, [.seconds(3), .seconds(3)])
    }

    func testEventsForDifferentMappingsScheduleSeparateRepairs() async {
        let clock = TestClock()
        let recorder = RepairRecorder()
        let firstID = UUID()
        let secondID = UUID()
        let scheduler = RepairScheduler(delay: .seconds(3), clock: clock) { id, _ in
            await recorder.record(id)
        }

        await scheduler.enqueue(mappingID: firstID, reason: .fileSystemChange)
        await scheduler.enqueue(mappingID: secondID, reason: .fileSystemChange)
        let sleepsStarted = await clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(sleepsStarted)
        await clock.advance(by: .seconds(3))
        await recorder.waitForCount(2)

        let recordedIDs = await recorder.ids
        XCTAssertEqual(Set(recordedIDs), [firstID, secondID])
    }

    @MainActor
    func testMonitorFiltersPathsAndSchedulesOnlyMatchingMappings() async {
        let clock = TestClock()
        let streamFactory = RecordingStreamFactory()
        let recorder = RepairRecorder()
        let firstMapping = makeMapping(applicationPath: "/Applications/First.app")
        let secondMapping = makeMapping(applicationPath: "/Applications/Second.app")
        let monitor = MappingFileMonitor(
            repairCoordinator: RepairCoordinator(applier: NoopApplier()),
            onRepair: { mapping in
                Task { await recorder.record(mapping.id) }
            },
            streamFactory: streamFactory.make,
            schedulerFactory: { repair, completion in
                RepairScheduler(
                    delay: .seconds(3),
                    clock: clock,
                    repair: repair,
                    repairCompletion: completion
                )
            }
        )

        await monitor.start(mappings: [firstMapping, secondMapping])
        streamFactory.latestStream?.emit(paths: [
            "/Applications/First.app/Contents/Info.plist",
            "/Applications/Unrelated.app/Contents/Info.plist",
        ])
        let sleepStarted = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sleepStarted)
        await clock.advance(by: .seconds(3))
        await recorder.waitForCount(1)

        let recordedIDs = await recorder.ids
        XCTAssertEqual(recordedIDs, [firstMapping.id])
    }

    @MainActor
    func testMonitorUsesUniqueParentsAndStopsPreviousStreamBeforeRecreating() async {
        let streamFactory = RecordingStreamFactory()
        let monitor = MappingFileMonitor(
            repairCoordinator: RepairCoordinator(applier: NoopApplier()),
            streamFactory: streamFactory.make
        )
        let firstMapping = makeMapping(applicationPath: "/Applications/First.app")
        let secondMapping = makeMapping(applicationPath: "/Applications/Second.app")
        let thirdMapping = makeMapping(applicationPath: "/Users/example/Applications/Third.app")

        await monitor.start(mappings: [firstMapping, secondMapping, thirdMapping])
        XCTAssertEqual(streamFactory.directorySets, [["/Applications", "/Users/example/Applications"]])
        let firstStream = try! XCTUnwrap(streamFactory.latestStream)
        XCTAssertEqual(firstStream.startCount, 1)

        await monitor.start(mappings: [thirdMapping])
        XCTAssertEqual(firstStream.stopCount, 1)
        XCTAssertEqual(streamFactory.directorySets.last, ["/Users/example/Applications"])
        let secondStream = try! XCTUnwrap(streamFactory.latestStream)

        await monitor.stop()
        XCTAssertEqual(secondStream.stopCount, 1)
    }

    @MainActor
    func testCancelAllSuppressesQueuedRepair() async {
        let clock = TestClock()
        let recorder = RepairRecorder()
        let mappingID = UUID()
        let scheduler = RepairScheduler(delay: .seconds(3), clock: clock) { id, _ in
            await recorder.record(id)
        }

        await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
        let sleepStarted = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sleepStarted)
        await scheduler.cancelAll()
        await clock.advance(by: .seconds(3))
        await Task.yield()

        let recordedIDs = await recorder.ids
        XCTAssertTrue(recordedIDs.isEmpty)
    }

    func testCancelAllWaitsForAnAwakenedRepairToFinish() async {
        let clock = TestClock()
        let repairGate = RepairGate()
        let completion = CompletionRecorder()
        let mappingID = UUID()
        let scheduler = RepairScheduler(delay: .seconds(3), clock: clock) { id, _ in
            await repairGate.repair(id)
        }

        await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
        let sleepStarted = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sleepStarted)
        await clock.advance(by: .seconds(3))
        let repairStarted = await repairGate.waitUntilRepairStarts()
        XCTAssertTrue(repairStarted)

        let cancellation = Task {
            await scheduler.cancelAll()
            await completion.recordCompletion()
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let completedBeforeRepair = await completion.hasCompleted
        XCTAssertFalse(completedBeforeRepair)

        await repairGate.releaseRepair()
        await cancellation.value
        let completedAfterRepair = await completion.hasCompleted
        XCTAssertTrue(completedAfterRepair)
    }

    @MainActor
    func testMonitorIgnoresEventsFromTheReplacedStream() async {
        let clock = TestClock()
        let streamFactory = RecordingStreamFactory()
        let oldMapping = makeMapping(applicationPath: "/Applications/Old.app")
        let newMapping = makeMapping(applicationPath: "/Applications/New.app")
        let monitor = MappingFileMonitor(
            repairCoordinator: RepairCoordinator(applier: NoopApplier()),
            streamFactory: streamFactory.make,
            schedulerFactory: { repair, completion in
                RepairScheduler(
                    delay: .seconds(3),
                    clock: clock,
                    repair: repair,
                    repairCompletion: completion
                )
            }
        )

        await monitor.start(mappings: [oldMapping])
        let oldStream = try! XCTUnwrap(streamFactory.latestStream)
        await monitor.start(mappings: [newMapping])
        oldStream.emit(paths: ["/Applications/Old.app"])
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let sleeperCount = await clock.sleeperCount
        XCTAssertEqual(sleeperCount, 0)
    }

    @MainActor
    func testMonitorDoesNotEnqueueAnOldGenerationAfterSchedulerSuspension() async {
        let clock = BlockingClock()
        let streamFactory = RecordingStreamFactory()
        let oldMapping = makeMapping(applicationPath: "/Applications/Old.app")
        let newMapping = makeMapping(applicationPath: "/Applications/New.app")
        let monitor = MappingFileMonitor(
            repairCoordinator: RepairCoordinator(applier: NoopApplier()),
            streamFactory: streamFactory.make,
            schedulerFactory: { repair, completion in
                RepairScheduler(
                    delay: .seconds(3),
                    clock: clock,
                    repair: repair,
                    repairCompletion: completion
                )
            }
        )

        await monitor.start(mappings: [oldMapping])
        let oldStream = try! XCTUnwrap(streamFactory.latestStream)
        oldStream.emit(paths: ["/Applications/Old.app"])
        let firstSleepStarted = await clock.waitUntilSleepRequested(count: 1)
        XCTAssertTrue(firstSleepStarted)

        oldStream.emit(paths: ["/Applications/Old.app"])
        let cancellationWasRequested = await clock.waitUntilCancellationRequested(count: 1)
        XCTAssertTrue(cancellationWasRequested)

        let restart = Task { @MainActor in
            await monitor.start(mappings: [newMapping])
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        await clock.releaseAllSleepers()
        await restart.value
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let requestedDurations = await clock.requestedDurations
        await clock.releaseAllSleepers()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(requestedDurations, [.seconds(3)])
    }

    @MainActor
    func testMonitorMatchesOnlyTheExactParentOrApplicationPathBoundary() async {
        let clock = TestClock()
        let streamFactory = RecordingStreamFactory()
        let mapping = makeMapping(applicationPath: "/Applications/Foo.app")
        let monitor = MappingFileMonitor(
            repairCoordinator: RepairCoordinator(applier: NoopApplier()),
            streamFactory: streamFactory.make,
            schedulerFactory: { repair, completion in
                RepairScheduler(
                    delay: .seconds(3),
                    clock: clock,
                    repair: repair,
                    repairCompletion: completion
                )
            }
        )

        await monitor.start(mappings: [mapping])
        let stream = try! XCTUnwrap(streamFactory.latestStream)
        stream.emit(paths: ["/Applications/Foo.app-copy/Contents/Info.plist"])
        try? await Task.sleep(for: .milliseconds(10))
        let prefixSleeperCount = await clock.sleeperCount
        XCTAssertEqual(prefixSleeperCount, 0)

        stream.emit(paths: ["/Applications"])
        let parentSleepStarted = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(parentSleepStarted)
    }

    @MainActor
    func testMovedApplicationReconfiguresAfterScheduledRepairCompletes() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let oldApplicationURL = temporaryDirectory
            .appending(path: "Old/Example.app", directoryHint: .isDirectory)
        let movedApplicationURL = temporaryDirectory
            .appending(path: "New/Example.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: movedApplicationURL, withIntermediateDirectories: true)

        let mapping = IconMapping(
            applicationURL: oldApplicationURL,
            bundleIdentifier: "com.example.Example",
            iconURL: temporaryDirectory.appending(path: "Example.icns")
        )
        let clock = TestClock()
        let streamFactory = RecordingStreamFactory()
        let coordinator = RepairCoordinator(
            fingerprinting: FixedFingerprint(),
            locator: FixedLocator(result: movedApplicationURL),
            applier: NoopApplier()
        )
        let monitor = MappingFileMonitor(
            repairCoordinator: coordinator,
            streamFactory: streamFactory.make,
            schedulerFactory: { repair, completion in
                RepairScheduler(
                    delay: .seconds(3),
                    clock: clock,
                    repair: repair,
                    repairCompletion: completion
                )
            }
        )

        await monitor.start(mappings: [mapping])
        let firstStream = try XCTUnwrap(streamFactory.latestStream)
        firstStream.emit(paths: [oldApplicationURL.path])
        let sleepStarted = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sleepStarted)
        await clock.advance(by: .seconds(3))

        let newParent = movedApplicationURL.deletingLastPathComponent().standardizedFileURL.path
        let reconfigured = await streamFactory.waitUntilDirectorySet(newParent)
        XCTAssertTrue(reconfigured)
        XCTAssertEqual(firstStream.stopCount, 1)
    }

    @MainActor
    func testOverlappingStartsLeaveOnlyTheNewestMappingStreamActive() async {
        let clock = BlockingClock()
        let streamFactory = RecordingStreamFactory()
        let initialMapping = makeMapping(applicationPath: "/Applications/Initial.app")
        let intermediateMapping = makeMapping(applicationPath: "/Applications/Intermediate.app")
        let newestMapping = makeMapping(applicationPath: "/Applications/Newest.app")
        let monitor = MappingFileMonitor(
            repairCoordinator: RepairCoordinator(applier: NoopApplier()),
            streamFactory: streamFactory.make,
            schedulerFactory: { repair, completion in
                RepairScheduler(
                    delay: .seconds(3),
                    clock: clock,
                    repair: repair,
                    repairCompletion: completion
                )
            }
        )

        await monitor.start(mappings: [initialMapping])
        let initialStream = try! XCTUnwrap(streamFactory.latestStream)
        initialStream.emit(paths: [initialMapping.applicationURL.path])
        let sleepStarted = await clock.waitUntilSleepRequested(count: 1)
        XCTAssertTrue(sleepStarted)

        let intermediateStart = Task { @MainActor in
            await monitor.start(mappings: [intermediateMapping])
        }
        let cancellationRequested = await clock.waitUntilCancellationRequested(count: 1)
        XCTAssertTrue(cancellationRequested)

        let newestStart = Task { @MainActor in
            await monitor.start(mappings: [newestMapping])
        }
        await clock.releaseAllSleepers()
        await intermediateStart.value
        await newestStart.value

        XCTAssertEqual(
            streamFactory.directorySets,
            [["/Applications"], ["/Applications"]]
        )
        XCTAssertEqual(initialStream.stopCount, 1)
        XCTAssertEqual(streamFactory.latestStream?.startCount, 1)
    }

    private func makeMapping(applicationPath: String) -> IconMapping {
        IconMapping(
            applicationURL: URL(filePath: applicationPath, directoryHint: .isDirectory),
            bundleIdentifier: nil,
            iconURL: URL(filePath: "/tmp/Test.icns")
        )
    }
}

private actor RepairRecorder {
    private(set) var ids: [UUID] = []

    func record(_ id: UUID) {
        ids.append(id)
    }

    func waitForCount(_ count: Int) async {
        while ids.count < count {
            await Task.yield()
        }
    }
}

private actor CompletionRecorder {
    private(set) var hasCompleted = false

    func recordCompletion() {
        hasCompleted = true
    }
}

private actor RepairGate {
    private var repairStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func repair(_: UUID) async {
        repairStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRepairStarts() async -> Bool {
        for _ in 0 ..< 100 {
            if repairStarted {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return repairStarted
    }

    func releaseRepair() {
        continuation?.resume()
        continuation = nil
    }
}

private struct FixedFingerprint: Fingerprinting {
    func fingerprint(of _: URL) throws -> String {
        "fingerprint"
    }
}

private struct FixedLocator: ApplicationLocating {
    let result: URL?

    func resolve(_: String) -> URL? {
        result
    }
}

private actor TestClock: RepairSchedulingClock {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var now: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private(set) var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requestedDurations.append(duration)
                sleepers[id] = Sleeper(deadline: now + duration, continuation: continuation)
                resumeDueSleepers()
            }
        } onCancel: {
            Task { await self.cancelSleeper(id) }
        }
    }

    func advance(by duration: Duration) {
        now += duration
        resumeDueSleepers()
    }

    func waitUntilSleeping(count: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if sleepers.count >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return sleepers.count >= count
    }

    func waitUntilSleepRequested(count: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if requestedDurations.count >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return requestedDurations.count >= count
    }

    var sleeperCount: Int {
        sleepers.count
    }

    private func cancelSleeper(_ id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else {
            return
        }
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private func resumeDueSleepers() {
        let dueIDs = sleepers.compactMap { id, sleeper in
            sleeper.deadline <= now ? id : nil
        }
        for id in dueIDs {
            guard let sleeper = sleepers.removeValue(forKey: id) else {
                continue
            }
            sleeper.continuation.resume()
        }
    }
}

private actor BlockingClock: RepairSchedulingClock {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDurations: [Duration] = []
    private var cancellationRequests = 0

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requestedDurations.append(duration)
                continuations.append(continuation)
            }
            if Task.isCancelled {
                throw CancellationError()
            }
        } onCancel: {
            Task { await self.recordCancellationRequest() }
        }
    }

    func waitUntilSleepRequested(count: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if requestedDurations.count >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return requestedDurations.count >= count
    }

    func waitUntilCancellationRequested(count: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if cancellationRequests >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return cancellationRequests >= count
    }

    func releaseAllSleepers() {
        let sleepers = continuations
        continuations.removeAll()
        for continuation in sleepers {
            continuation.resume()
        }
    }

    private func recordCancellationRequest() {
        cancellationRequests += 1
    }
}

@MainActor
private final class RecordingStreamFactory {
    private(set) var directorySets: [Set<String>] = []
    private(set) var streams: [FakeMappingEventStream] = []

    var latestStream: FakeMappingEventStream? {
        streams.last
    }

    func make(
        directories: Set<String>,
        handler: @escaping @Sendable ([String]) -> Void
    ) -> any MappingEventStream {
        directorySets.append(directories)
        let stream = FakeMappingEventStream(handler: handler)
        streams.append(stream)
        return stream
    }

    func waitUntilDirectorySet(_ directory: String) async -> Bool {
        for _ in 0 ..< 100 {
            if directorySets.contains([directory]) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return directorySets.contains([directory])
    }
}

@MainActor
private final class FakeMappingEventStream: MappingEventStream {
    private let handler: @Sendable ([String]) -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit(paths: [String]) {
        handler(paths)
    }
}

private struct NoopApplier: IconApplying {
    func apply(applicationURL _: URL, iconURL _: URL) async throws {}
}
