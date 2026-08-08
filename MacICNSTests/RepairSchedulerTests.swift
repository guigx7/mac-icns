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
            schedulerFactory: { repair in
                RepairScheduler(delay: .seconds(3), clock: clock, repair: repair)
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

    @MainActor
    func testMonitorIgnoresEventsFromTheReplacedStream() async {
        let clock = TestClock()
        let streamFactory = RecordingStreamFactory()
        let oldMapping = makeMapping(applicationPath: "/Applications/Old.app")
        let newMapping = makeMapping(applicationPath: "/Applications/New.app")
        let monitor = MappingFileMonitor(
            repairCoordinator: RepairCoordinator(applier: NoopApplier()),
            streamFactory: streamFactory.make,
            schedulerFactory: { repair in
                RepairScheduler(delay: .seconds(3), clock: clock, repair: repair)
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
            await Task.yield()
        }
        return sleepers.count >= count
    }

    func waitUntilSleepRequested(count: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if requestedDurations.count >= count {
                return true
            }
            await Task.yield()
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
