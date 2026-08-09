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
    typealias RepairCompletion = @Sendable (UUID) async -> Void

    private struct PendingRepair {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let delay: Duration
    private let clock: any RepairSchedulingClock
    private let repair: Repair
    private let repairCompletion: RepairCompletion
    private var pendingRepairs: [UUID: PendingRepair] = [:]
    private var activeGeneration = 0

    init(
        delay: Duration = .seconds(3),
        clock: any RepairSchedulingClock = ContinuousRepairSchedulingClock(),
        repair: @escaping Repair,
        repairCompletion: @escaping RepairCompletion = { _ in }
    ) {
        self.delay = delay
        self.clock = clock
        self.repair = repair
        self.repairCompletion = repairCompletion
    }

    func enqueue(mappingID: UUID, reason: RepairReason) async {
        await enqueue(mappingID: mappingID, reason: reason, generation: activeGeneration)
    }

    func enqueue(mappingID: UUID, reason: RepairReason, generation: Int) async {
        guard generation == activeGeneration else {
            return
        }

        await cancelAndWaitForPendingRepair(mappingID: mappingID)

        guard generation == activeGeneration else {
            return
        }

        let token = UUID()
        let task = Task { [weak self, clock, delay, repair] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                await self?.finish(mappingID: mappingID, token: token, notifyCompletion: false)
                return
            }

            guard !Task.isCancelled else {
                await self?.finish(mappingID: mappingID, token: token, notifyCompletion: false)
                return
            }

            await repair(mappingID, reason)
            await self?.finish(mappingID: mappingID, token: token, notifyCompletion: true)
        }
        pendingRepairs[mappingID] = PendingRepair(token: token, task: task)
    }

    func beginGeneration(_ generation: Int) async {
        activeGeneration = generation
        await cancelAllPendingRepairs()
    }

    func cancelAll() async {
        activeGeneration += 1
        await cancelAllPendingRepairs()
    }

    private func cancelAndWaitForPendingRepair(mappingID: UUID) async {
        while let pendingRepair = pendingRepairs[mappingID] {
            pendingRepair.task.cancel()
            await pendingRepair.task.value

            guard pendingRepairs[mappingID]?.token == pendingRepair.token else {
                continue
            }
            pendingRepairs[mappingID] = nil
        }
    }

    private func cancelAllPendingRepairs() async {
        let repairs = Array(pendingRepairs.values)

        for pendingRepair in repairs {
            pendingRepair.task.cancel()
        }
        for pendingRepair in repairs {
            await pendingRepair.task.value
        }
    }

    private func finish(mappingID: UUID, token: UUID, notifyCompletion: Bool) async {
        guard pendingRepairs[mappingID]?.token == token else {
            return
        }
        pendingRepairs[mappingID] = nil
        if notifyCompletion {
            await repairCompletion(mappingID)
        }
    }
}
