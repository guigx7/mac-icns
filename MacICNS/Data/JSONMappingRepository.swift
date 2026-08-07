import Foundation

struct JSONMappingRepository: MappingRepository {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> [IconMapping] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        return try JSONDecoder().decode([IconMapping].self, from: Data(contentsOf: fileURL))
    }

    func save(_ mappings: [IconMapping]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(mappings)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return applicationSupportDirectory
            .appending(path: "MacICNS", directoryHint: .isDirectory)
            .appending(path: "mappings.json")
    }
}
