import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var mappings: [IconMapping] = []
    @Published private(set) var persistenceError: String?
    @Published private(set) var helperStatus: HelperInstallationService.Status
    @Published private(set) var helperError: String?
    @Published private(set) var operationError: String?
    @Published private(set) var busyMappingIDs: Set<UUID> = []

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
        helperStatus = helperInstallationService.status
    }

    func launch() {
        guard !hasLaunched else {
            return
        }
        hasLaunched = true
        refreshHelperStatus()
        loadMappings()
    }

    func loadMappings() {
        do {
            mappings = try repository.load()
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
        mappingRevision += 1
        let repairedMapping = await repairCoordinator.repair(mapping, reason: reason)
        replace(repairedMapping)
        saveMappings()
        await monitor.start(mappings: mappings)
    }

    func refreshAll() async {
        mappingRevision += 1
        recordDiagnostic("Manual icon refresh requested.")
        mappings = await repairCoordinator.repairAll(mappings, reason: .manual)
        saveMappings()
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
        if updated.isEnabled != isEnabled {
            operationError = updated.status == .needsPermission
                ? "The privileged helper is required to change this icon."
                : "The icon could not be changed. Please try again."
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
            saveMappings()
            await monitor.start(mappings: mappings)
            recordDiagnostic("Restored the original icon and deleted mapping \(mapping.id).")
        } catch {
            operationError = "The original icon could not be restored, so the mapping was not deleted."
            recordDiagnostic("Could not delete mapping \(mapping.id): \(error.localizedDescription)")
        }
    }

    func isBusy(_ mapping: IconMapping) -> Bool {
        busyMappingIDs.contains(mapping.id)
    }

    func dismissOperationError() {
        operationError = nil
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    func refreshHelperStatus() {
        let previousStatus = helperStatus
        helperStatus = helperInstallationService.status
        helperError = nil
        if helperStatus == .requiresApproval {
            recordDiagnostic("Privileged helper requires approval.")
        }
        if previousStatus != .installed, helperStatus == .installed {
            recordDiagnostic("Privileged helper became available; refreshing icons.")
            Task { [weak self] in
                await self?.refreshAll()
            }
        }
    }

    func installHelper() {
        do {
            try helperInstallationService.install()
            helperError = nil
            recordDiagnostic("Privileged helper registration requested.")
            refreshHelperStatus()
        } catch {
            helperError = "Could not install the helper: \(error.localizedDescription)"
            recordDiagnostic("Could not install privileged helper: \(error.localizedDescription)")
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
}
