import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var mappings: [IconMapping] = []
    @Published private(set) var persistenceError: String?
    @Published private(set) var helperStatus: HelperInstallationService.OperationalStatus
    @Published private(set) var helperError: String?
    @Published private(set) var helperIsUpdating = false
    @Published private(set) var operationError: String?
    @Published private(set) var busyMappingIDs: Set<UUID> = []
    @Published private(set) var mappingFailureMessages: [UUID: String] = [:]

    private let repository: any MappingRepository
    private let repairCoordinator: RepairCoordinator
    private let helperInstallationService: HelperInstallationService
    private let diagnosticLogger: DiagnosticLogger
    private var hasLaunched = false
    private var mappingRevision = 0
    private lazy var monitor = MappingFileMonitor(repairCoordinator: repairCoordinator) { [weak self] mapping in
        guard let self else {
            return
        }
        self.replace(mapping)
        self.saveMappings()
        Task { await self.synchronizeFailureDetails(for: [mapping]) }
    }

    init(
        repository: any MappingRepository = JSONMappingRepository(),
        repairCoordinator: RepairCoordinator = RepairCoordinator(applier: IconApplierRouter()),
        helperInstallationService: HelperInstallationService = HelperInstallationService(),
        diagnosticLogger: DiagnosticLogger = DiagnosticLogger()
    ) {
        self.repository = repository
        self.repairCoordinator = repairCoordinator
        self.helperInstallationService = helperInstallationService
        self.diagnosticLogger = diagnosticLogger
        helperStatus = helperInstallationService.initialOperationalStatus
    }

    func launch() {
        guard !hasLaunched else {
            return
        }
        hasLaunched = true
        Task { [weak self] in
            await self?.refreshHelperStatus()
        }
        loadMappings()
    }

    func loadMappings() {
        do {
            mappings = try repository.load()
            mappingFailureMessages = [:]
            mappingRevision += 1
            let revision = mappingRevision
            persistenceError = nil
            recordDiagnostic("Loaded \(mappings.count) icon mappings.")
            Task { [weak self] in
                await self?.startMonitoringAndRepair(revision: revision)
            }
        } catch {
            persistenceError = "Could not load saved mappings."
            recordDiagnostic("Could not load saved mappings: \(error.localizedDescription)")
        }
    }

    func addMapping(applicationURL: URL, iconURL: URL) async {
        let mapping = IconMapping(
            applicationURL: applicationURL,
            bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier,
            iconURL: iconURL
        )
        mappings.append(mapping)
        mappingRevision += 1
        saveMappings()
        await monitor.start(mappings: mappings)
        await apply(mapping, reason: .mappingEdited)
    }

    func apply(_ mapping: IconMapping, reason: RepairReason = .manual) async {
        guard !busyMappingIDs.contains(mapping.id) else {
            return
        }
        busyMappingIDs.insert(mapping.id)
        defer { busyMappingIDs.remove(mapping.id) }
        mappingRevision += 1
        let repairedMapping = await repairCoordinator.repair(mapping, reason: reason)
        replace(repairedMapping)
        saveMappings()
        await synchronizeFailureDetails(for: [repairedMapping])
        await monitor.start(mappings: mappings)
    }

    func replaceIcon(for mapping: IconMapping, with iconURL: URL) async {
        guard !busyMappingIDs.contains(mapping.id),
              let current = mappings.first(where: { $0.id == mapping.id })
        else {
            return
        }
        busyMappingIDs.insert(mapping.id)
        defer { busyMappingIDs.remove(mapping.id) }
        mappingRevision += 1
        operationError = nil

        var candidate = current
        candidate.iconURL = iconURL.standardizedFileURL
        candidate.appFingerprint = nil
        candidate.iconFingerprint = nil
        candidate.lastSuccessAt = nil

        guard candidate.isEnabled else {
            replace(candidate)
            mappingFailureMessages[candidate.id] = nil
            saveMappings()
            await monitor.start(mappings: mappings)
            recordDiagnostic("Changed the icon file for disabled mapping \(candidate.id).")
            return
        }

        let repaired = await repairCoordinator.repair(candidate, reason: .mappingEdited)
        guard repaired.status == .upToDate else {
            await synchronizeFailureDetails(for: [repaired])
            operationError = mappingFailureMessages[repaired.id]
                ?? "The new icon could not be applied, so the previous mapping was preserved."
            await monitor.start(mappings: mappings)
            recordDiagnostic("Could not replace the icon file for mapping \(candidate.id).")
            return
        }

        replace(repaired)
        await synchronizeFailureDetails(for: [repaired])
        saveMappings()
        await monitor.start(mappings: mappings)
        recordDiagnostic("Replaced and applied the icon file for mapping \(candidate.id).")
    }

    func refreshAll() async {
        await refreshAll(reason: .manual, diagnosticMessage: "Manual icon refresh requested.")
    }

    private func refreshAll(reason: RepairReason, diagnosticMessage: String) async {
        guard busyMappingIDs.isEmpty else {
            return
        }
        let snapshot = mappings
        let refreshedIDs = Set(snapshot.map(\.id))
        busyMappingIDs.formUnion(refreshedIDs)
        defer { busyMappingIDs.subtract(refreshedIDs) }
        mappingRevision += 1
        let revision = mappingRevision
        recordDiagnostic(diagnosticMessage)
        let repairedMappings = await repairCoordinator.repairAll(snapshot, reason: reason)
        guard mappingRevision == revision else {
            recordDiagnostic("Discarded a stale manual refresh result after mappings changed.")
            return
        }
        mappings = repairedMappings
        saveMappings()
        await synchronizeFailureDetails(for: repairedMappings)
        await monitor.start(mappings: mappings)
    }

    func removeMappings(at offsets: IndexSet) {
        let targets = offsets.compactMap { index in
            mappings.indices.contains(index) ? mappings[index] : nil
        }
        Task { [weak self] in
            for mapping in targets {
                await self?.delete(mapping)
            }
        }
    }

    func setEnabled(_ isEnabled: Bool, for mapping: IconMapping) async {
        guard !busyMappingIDs.contains(mapping.id) else {
            return
        }
        busyMappingIDs.insert(mapping.id)
        defer { busyMappingIDs.remove(mapping.id) }
        mappingRevision += 1
        operationError = nil

        let updated = await repairCoordinator.setEnabled(isEnabled, for: mapping)
        replace(updated)
        await synchronizeFailureDetails(for: [updated])
        if updated.isEnabled != isEnabled {
            operationError = mappingFailureMessages[updated.id]
                ?? "The icon could not be changed. Please try again."
            recordDiagnostic("Could not set mapping \(mapping.id) enabled state to \(isEnabled).")
        } else {
            recordDiagnostic("Set mapping \(mapping.id) enabled state to \(isEnabled).")
        }
        saveMappings()
        await monitor.start(mappings: mappings)
    }

    func delete(_ mapping: IconMapping) async {
        guard !busyMappingIDs.contains(mapping.id),
              mappings.contains(where: { $0.id == mapping.id })
        else {
            return
        }
        busyMappingIDs.insert(mapping.id)
        defer { busyMappingIDs.remove(mapping.id) }
        mappingRevision += 1
        operationError = nil

        do {
            try await repairCoordinator.resetForRemoval(mapping)
            mappings.removeAll(where: { $0.id == mapping.id })
            mappingFailureMessages[mapping.id] = nil
            saveMappings()
            await monitor.start(mappings: mappings)
            recordDiagnostic("Restored the original icon and deleted mapping \(mapping.id).")
        } catch {
            await synchronizeFailureDetails(for: [mapping])
            operationError = mappingFailureMessages[mapping.id]
                ?? "The original icon could not be restored, so the mapping was not deleted."
            recordDiagnostic("Could not delete mapping \(mapping.id).")
        }
    }

    func isBusy(_ mapping: IconMapping) -> Bool {
        busyMappingIDs.contains(mapping.id)
    }

    func failureMessage(for mapping: IconMapping) -> String? {
        mappingFailureMessages[mapping.id]
    }

    func dismissOperationError() {
        operationError = nil
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    func refreshHelperStatus() async {
        let previousStatus = helperStatus
        helperStatus = await helperInstallationService.operationalStatus()
        helperError = nil
        if helperStatus == .requiresApproval {
            recordDiagnostic("Privileged helper requires approval.")
        }
        if previousStatus != .installed, helperStatus == .installed {
            recordDiagnostic("Privileged helper became available; refreshing icons.")
            await refreshAll(
                reason: .helperUpdated,
                diagnosticMessage: "Reapplying icons after helper became available."
            )
        }
    }

    func installHelper() async {
        guard !helperIsUpdating else { return }
        helperIsUpdating = true
        helperError = nil
        defer { helperIsUpdating = false }

        do {
            try await helperInstallationService.installAndWaitUntilReady()
            helperStatus = await helperInstallationService.operationalStatus()
            guard helperStatus == .installed else {
                helperError = "The helper was registered but stopped responding. Please try again."
                recordDiagnostic("Privileged helper stopped responding after installation.")
                return
            }
            helperError = nil
            recordDiagnostic("Privileged helper was installed successfully.")
            await refreshAll(
                reason: .helperUpdated,
                diagnosticMessage: "Reapplying enabled icons after helper installation."
            )
        } catch {
            helperStatus = await helperInstallationService.operationalStatus()
            helperError = "Could not install the helper: \(error.localizedDescription)"
            recordDiagnostic("Could not install privileged helper: \(error.localizedDescription)")
        }
    }

    func updateHelper() async {
        guard !helperIsUpdating else { return }
        helperIsUpdating = true
        helperError = nil
        defer { helperIsUpdating = false }

        do {
            try await helperInstallationService.update()
            helperStatus = await helperInstallationService.operationalStatus()
            guard helperStatus == .installed else {
                helperError = "The helper was updated but stopped responding. Please try again."
                recordDiagnostic("Privileged helper stopped responding after update.")
                return
            }
            recordDiagnostic("Privileged helper was updated successfully.")
            await refreshAll(
                reason: .helperUpdated,
                diagnosticMessage: "Reapplying enabled icons after helper update."
            )
        } catch {
            helperStatus = await helperInstallationService.operationalStatus()
            helperError = "Could not update the helper: \(error.localizedDescription)"
            recordDiagnostic("Could not update privileged helper: \(sanitizedDescription(error))")
        }
    }

    func openHelperApprovalSettings() {
        helperInstallationService.openLoginItemsAndExtensions()
    }

    private func replace(_ mapping: IconMapping) {
        guard let index = mappings.firstIndex(where: { $0.id == mapping.id }) else {
            return
        }
        mappings[index] = mapping
    }

    private func startMonitoringAndRepair(revision: Int) async {
        guard mappingRevision == revision else {
            return
        }
        let snapshot = mappings
        await monitor.start(mappings: snapshot)
        let repairedMappings = await repairCoordinator.repairAll(snapshot, reason: .launch)
        guard mappingRevision == revision else {
            return
        }
        mappings = repairedMappings
        saveMappings()
        await synchronizeFailureDetails(for: repairedMappings)
        await monitor.start(mappings: mappings)
    }

    private func saveMappings() {
        do {
            try repository.save(mappings)
            persistenceError = nil
        } catch {
            persistenceError = "Could not save mappings."
            recordDiagnostic("Could not save mappings: \(error.localizedDescription)")
        }
    }

    private func recordDiagnostic(_ message: String) {
        try? diagnosticLogger.record(message)
    }

    private func synchronizeFailureDetails(for mappings: [IconMapping]) async {
        for mapping in mappings {
            if let details = await repairCoordinator.failureDetails(for: mapping.id) {
                let previousMessage = mappingFailureMessages[mapping.id]
                mappingFailureMessages[mapping.id] = details.userMessage
                if previousMessage != details.userMessage {
                    recordDiagnostic("Icon mapping \(mapping.id) failed: \(details.diagnosticSummary)")
                }
            } else {
                mappingFailureMessages[mapping.id] = nil
            }
        }
    }

    private func sanitizedDescription(_ error: Error) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return "domain=\(String(nsError.domain.prefix(200))) code=\(nsError.code) description=\(String(description.prefix(300)))"
    }
}
