import Foundation

protocol RepairSchedulingClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousRepairSchedulingClock: RepairSchedulingClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

actor RepairScheduler {
    typealias Repair = @Sendable (UUID, RepairReason) async -> Void

    private struct PendingRepair {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let delay: Duration
    private let clock: any RepairSchedulingClock
    private let repair: Repair
    private var pendingRepairs: [UUID: PendingRepair] = [:]

    init(
        delay: Duration = .seconds(3),
        clock: any RepairSchedulingClock = ContinuousRepairSchedulingClock(),
        repair: @escaping Repair
    ) {
        self.delay = delay
        self.clock = clock
        self.repair = repair
    }

    func enqueue(mappingID: UUID, reason: RepairReason) {
        pendingRepairs[mappingID]?.task.cancel()

        let token = UUID()
        let task = Task { [clock, delay, repair] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            await repair(mappingID, reason)
        }
        pendingRepairs[mappingID] = PendingRepair(token: token, task: task)

        Task { [weak self] in
            await task.value
            await self?.finish(mappingID: mappingID, token: token)
        }
    }

    func cancelAll() {
        for pendingRepair in pendingRepairs.values {
            pendingRepair.task.cancel()
        }
        pendingRepairs.removeAll()
    }

    private func finish(mappingID: UUID, token: UUID) {
        guard pendingRepairs[mappingID]?.token == token else {
            return
        }
        pendingRepairs[mappingID] = nil
    }
}
