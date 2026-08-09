import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var mappings: [IconMapping] = []
    @Published private(set) var persistenceError: String?
    @Published private(set) var helperStatus: HelperInstallationService.Status
    @Published private(set) var helperError: String?

    private let repository: any MappingRepository
    private let repairCoordinator: RepairCoordinator
    private let helperInstallationService: HelperInstallationService
    private let diagnosticLogger: DiagnosticLogger
    private var hasLaunched = false
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
            persistenceError = nil
            recordDiagnostic("Loaded \(mappings.count) icon mappings.")
            Task { [weak self] in
                await self?.startMonitoringAndRepair()
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
        saveMappings()
        await monitor.start(mappings: mappings)
        await apply(mapping, reason: .mappingEdited)
    }

    func apply(_ mapping: IconMapping, reason: RepairReason = .manual) async {
        let repairedMapping = await repairCoordinator.repair(mapping, reason: reason)
        replace(repairedMapping)
        saveMappings()
        await monitor.start(mappings: mappings)
    }

    func refreshAll() async {
        recordDiagnostic("Manual icon refresh requested.")
        mappings = await repairCoordinator.repairAll(mappings, reason: .manual)
        saveMappings()
        await monitor.start(mappings: mappings)
    }

    func removeMappings(at offsets: IndexSet) {
        mappings.remove(atOffsets: offsets)
        saveMappings()
        Task { [weak self] in
            guard let self else {
                return
            }
            await self.monitor.start(mappings: self.mappings)
        }
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

    private func startMonitoringAndRepair() async {
        await monitor.start(mappings: mappings)
        mappings = await repairCoordinator.repairAll(reason: .launch)
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
