import CoreServices
import Foundation

@MainActor
final class MappingFileMonitor {
    typealias RepairHandler = @MainActor @Sendable (IconMapping) -> Void

    private let repairCoordinator: RepairCoordinator
    private let onRepair: RepairHandler
    private let streamQueue = DispatchQueue(label: "com.guigx.macicns.mapping-file-monitor")
    private var scheduler: RepairScheduler!
    private var mappingsByID: [UUID: IconMapping] = [:]
    private var stream: FSEventStreamRef?

    init(
        repairCoordinator: RepairCoordinator,
        onRepair: @escaping RepairHandler = { _ in }
    ) {
        self.repairCoordinator = repairCoordinator
        self.onRepair = onRepair
        scheduler = RepairScheduler { [weak self] mappingID, reason in
            await self?.repair(mappingID: mappingID, reason: reason)
        }
    }

    func start(mappings: [IconMapping]) {
        mappingsByID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.id, $0) })
        Task {
            await repairCoordinator.setMappings(mappings)
        }
        recreateStream()
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        Task {
            await scheduler.cancelAll()
        }
    }

    private func recreateStream() {
        stopStream()

        let directories = Set(mappingsByID.values.map { mapping in
            mapping.applicationURL.deletingLastPathComponent().standardizedFileURL.path
        })

        guard !directories.isEmpty else {
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            mappingFileMonitorCallback,
            &context,
            Array(directories).sorted() as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, streamQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func process(eventsAtPaths paths: [String]) {
        let affectedIDs = Set(paths.flatMap(affectedMappingIDs(forEventAtPath:)))
        for mappingID in affectedIDs {
            Task {
                await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
            }
        }
    }

    private func affectedMappingIDs(forEventAtPath path: String) -> [UUID] {
        let eventURL = URL(filePath: path).standardizedFileURL
        return mappingsByID.values.compactMap { mapping in
            let applicationURL = mapping.applicationURL.standardizedFileURL
            let parentURL = applicationURL.deletingLastPathComponent().standardizedFileURL
            guard eventURL == applicationURL
                || eventURL.path.hasPrefix(applicationURL.path + "/")
                || eventURL == parentURL
            else {
                return nil
            }
            return mapping.id
        }
    }

    private func repair(mappingID: UUID, reason: RepairReason) async {
        guard let mapping = mappingsByID[mappingID] else {
            return
        }

        let repairedMapping = await repairCoordinator.repair(mapping, reason: reason)
        mappingsByID[repairedMapping.id] = repairedMapping
        if repairedMapping.applicationURL.deletingLastPathComponent().standardizedFileURL
            != mapping.applicationURL.deletingLastPathComponent().standardizedFileURL {
            recreateStream()
        }
        onRepair(repairedMapping)
    }
}

private let mappingFileMonitorCallback: FSEventStreamCallback = { _, info, eventCount, paths, _, _ in
    guard let info else {
        return
    }

    let monitor = Unmanaged<MappingFileMonitor>.fromOpaque(info).takeUnretainedValue()
    let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    let pathsToProcess = Array(eventPaths.prefix(Int(eventCount)))
    Task { @MainActor in
        monitor.process(eventsAtPaths: pathsToProcess)
    }
}
