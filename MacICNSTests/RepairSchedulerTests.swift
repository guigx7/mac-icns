import Foundation
import XCTest
@testable import MacICNS

final class RepairSchedulerTests: XCTestCase {
    func testMultipleEventsScheduleOneRepair() async {
        let clock = TestClock()
        let recorder = RepairRecorder()
        let mappingID = UUID()
        let scheduler = RepairScheduler(delay: .seconds(3), clock: clock) { id, _ in
            await recorder.record(id)
        }

        await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
        await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
        await Task.yield()
        await clock.advance(by: .seconds(3))
        await Task.yield()

        let recordedIDs = await recorder.ids
        XCTAssertEqual(recordedIDs, [mappingID])
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
        await Task.yield()
        await clock.advance(by: .seconds(3))
        await Task.yield()

        let recordedIDs = await recorder.ids
        XCTAssertEqual(Set(recordedIDs), [firstID, secondID])
    }
}

private actor RepairRecorder {
    private(set) var ids: [UUID] = []

    func record(_ id: UUID) {
        ids.append(id)
    }
}

private actor TestClock: RepairSchedulingClock {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: Duration) async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func advance(by _: Duration) {
        let sleepingTasks = continuations
        continuations.removeAll()
        for continuation in sleepingTasks {
            continuation.resume()
        }
    }
}
