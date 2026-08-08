import CoreServices
import Foundation

@MainActor
protocol MappingEventStream: AnyObject {
    func start()
    func stop()
}

typealias MappingEventStreamFactory = @MainActor (
    Set<String>,
    @escaping @Sendable ([String]) -> Void
) -> any MappingEventStream

typealias RepairSchedulerFactory = (
    @escaping RepairScheduler.Repair,
    @escaping RepairScheduler.RepairCompletion
) -> RepairScheduler

@MainActor
final class MappingFileMonitor {
    typealias RepairHandler = @MainActor @Sendable (IconMapping) -> Void

    private let repairCoordinator: RepairCoordinator
    private let onRepair: RepairHandler
    private let streamFactory: MappingEventStreamFactory
    private let schedulerFactory: RepairSchedulerFactory
    private lazy var scheduler: RepairScheduler = schedulerFactory(
        { [weak self] mappingID, reason in
            await self?.repair(mappingID: mappingID, reason: reason)
        },
        { [weak self] mappingID in
            await self?.repairDidFinish(mappingID: mappingID)
        }
    )
    private var mappingsByID: [UUID: IconMapping] = [:]
    private var stream: (any MappingEventStream)?
    private var streamGeneration = 0
    private var mappingsAwaitingReconfiguration: Set<UUID> = []

    init(
        repairCoordinator: RepairCoordinator,
        onRepair: @escaping RepairHandler = { _ in },
        streamFactory: @escaping MappingEventStreamFactory = MappingFileMonitor.makeFSEventStream,
        schedulerFactory: @escaping RepairSchedulerFactory = { repair, completion in
            RepairScheduler(repair: repair, repairCompletion: completion)
        }
    ) {
        self.repairCoordinator = repairCoordinator
        self.onRepair = onRepair
        self.streamFactory = streamFactory
        self.schedulerFactory = schedulerFactory
    }

    func start(mappings: [IconMapping]) async {
        streamGeneration += 1
        let generation = streamGeneration
        stopStream()
        await scheduler.beginGeneration(generation)

        guard streamGeneration == generation else {
            return
        }

        mappingsByID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.id, $0) })
        await repairCoordinator.setMappings(mappings)

        guard streamGeneration == generation else {
            return
        }

        let directories = Set(mappings.map {
            $0.applicationURL.deletingLastPathComponent().standardizedFileURL.path
        })
        guard !directories.isEmpty else {
            return
        }

        let stream = streamFactory(directories) { [weak self] paths in
            Task { @MainActor in
                guard let self, self.streamGeneration == generation else {
                    return
                }
                await self.process(eventsAtPaths: paths, generation: generation)
            }
        }
        self.stream = stream
        stream.start()
    }

    func stop() async {
        streamGeneration += 1
        stopStream()
        await scheduler.beginGeneration(streamGeneration)
    }

    private func stopStream() {
        stream?.stop()
        stream = nil
    }

    func process(eventsAtPaths paths: [String], generation: Int) async {
        let affectedIDs = Set(paths.flatMap(affectedMappingIDs(forEventAtPath:)))
        for mappingID in affectedIDs {
            guard streamGeneration == generation else {
                return
            }
            await scheduler.enqueue(
                mappingID: mappingID,
                reason: .fileSystemChange,
                generation: generation
            )
            guard streamGeneration == generation else {
                return
            }
        }
    }

    private func affectedMappingIDs(forEventAtPath path: String) -> [UUID] {
        let eventPath = URL(filePath: path).standardizedFileURL.path
        return mappingsByID.values.compactMap { mapping in
            let applicationPath = mapping.applicationURL.standardizedFileURL.path
            let parentPath = mapping.applicationURL
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            guard eventPath == applicationPath
                || eventPath.hasPrefix(applicationPath + "/")
                || eventPath == parentPath
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
            mappingsAwaitingReconfiguration.insert(repairedMapping.id)
        }
        onRepair(repairedMapping)
    }

    private func repairDidFinish(mappingID: UUID) async {
        guard mappingsAwaitingReconfiguration.remove(mappingID) != nil else {
            return
        }
        await start(mappings: Array(mappingsByID.values))
    }

    private static func makeFSEventStream(
        directories: Set<String>,
        handler: @escaping @Sendable ([String]) -> Void
    ) -> any MappingEventStream {
        FSEventMappingEventStream(directories: directories, handler: handler)
    }
}

private final class FSEventCallbackContext: @unchecked Sendable {
    let handler: @Sendable ([String]) -> Void

    init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }
}

@MainActor
private final class FSEventMappingEventStream: MappingEventStream {
    private let callbackContext: FSEventCallbackContext
    private let stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.guigx.macicns.mapping-file-monitor")

    init(directories: Set<String>, handler: @escaping @Sendable ([String]) -> Void) {
        callbackContext = FSEventCallbackContext(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            mappingFileMonitorCallback,
            &context,
            Array(directories).sorted() as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
    }

    func start() {
        guard let stream else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

private let mappingFileMonitorCallback: FSEventStreamCallback = { _, info, eventCount, paths, _, _ in
    guard let info else {
        return
    }

    let context = Unmanaged<FSEventCallbackContext>.fromOpaque(info).takeUnretainedValue()
    let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    context.handler(Array(eventPaths.prefix(Int(eventCount))))
}
