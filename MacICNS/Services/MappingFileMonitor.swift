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

typealias RepairSchedulerFactory = (@escaping RepairScheduler.Repair) -> RepairScheduler

@MainActor
final class MappingFileMonitor {
    typealias RepairHandler = @MainActor @Sendable (IconMapping) -> Void

    private let repairCoordinator: RepairCoordinator
    private let onRepair: RepairHandler
    private let streamFactory: MappingEventStreamFactory
    private let schedulerFactory: RepairSchedulerFactory
    private lazy var scheduler: RepairScheduler = schedulerFactory { [weak self] mappingID, reason in
        await self?.repair(mappingID: mappingID, reason: reason)
    }
    private var mappingsByID: [UUID: IconMapping] = [:]
    private var stream: (any MappingEventStream)?
    private var streamGeneration = 0

    init(
        repairCoordinator: RepairCoordinator,
        onRepair: @escaping RepairHandler = { _ in },
        streamFactory: @escaping MappingEventStreamFactory = MappingFileMonitor.makeFSEventStream,
        schedulerFactory: @escaping RepairSchedulerFactory = { repair in RepairScheduler(repair: repair) }
    ) {
        self.repairCoordinator = repairCoordinator
        self.onRepair = onRepair
        self.streamFactory = streamFactory
        self.schedulerFactory = schedulerFactory
    }

    func start(mappings: [IconMapping]) async {
        streamGeneration += 1
        stopStream()
        await scheduler.cancelAll()

        mappingsByID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.id, $0) })
        await repairCoordinator.setMappings(mappings)

        let directories = Set(mappings.map {
            $0.applicationURL.deletingLastPathComponent().standardizedFileURL.path
        })
        guard !directories.isEmpty else {
            return
        }

        let generation = streamGeneration
        let stream = streamFactory(directories) { [weak self] paths in
            Task { @MainActor in
                guard let self, self.streamGeneration == generation else {
                    return
                }
                await self.process(eventsAtPaths: paths)
            }
        }
        self.stream = stream
        stream.start()
    }

    func stop() async {
        streamGeneration += 1
        stopStream()
        await scheduler.cancelAll()
    }

    private func stopStream() {
        stream?.stop()
        stream = nil
    }

    private func process(eventsAtPaths paths: [String]) async {
        let affectedIDs = Set(paths.flatMap(affectedMappingIDs(forEventAtPath:)))
        for mappingID in affectedIDs {
            await scheduler.enqueue(mappingID: mappingID, reason: .fileSystemChange)
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
            await start(mappings: Array(mappingsByID.values))
        }
        onRepair(repairedMapping)
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
