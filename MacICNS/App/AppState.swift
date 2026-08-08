import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var mappings: [IconMapping] = []
    @Published private(set) var persistenceError: String?

    private let repository: any MappingRepository
    private let repairCoordinator: RepairCoordinator
    private lazy var monitor = MappingFileMonitor(repairCoordinator: repairCoordinator) { [weak self] mapping in
        guard let self else {
            return
        }
        self.replace(mapping)
        self.saveMappings()
    }

    init(
        repository: any MappingRepository = JSONMappingRepository(),
        repairCoordinator: RepairCoordinator = RepairCoordinator(applier: DirectIconApplier())
    ) {
        self.repository = repository
        self.repairCoordinator = repairCoordinator
    }

    func loadMappings() {
        do {
            mappings = try repository.load()
            persistenceError = nil
            Task { [weak self] in
                await self?.startMonitoringAndRepair()
            }
        } catch {
            persistenceError = "Could not load saved mappings."
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
        }
    }
}
