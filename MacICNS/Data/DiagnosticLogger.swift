import Foundation

final class DiagnosticLogger {
    static let maximumFileSize = 1_024 * 1_024

    private let fileURL: URL
    private let maximumFileSize: Int
    private let lock = NSLock()

    init(
        fileURL: URL = DiagnosticLogger.defaultFileURL,
        maximumFileSize: Int = DiagnosticLogger.maximumFileSize
    ) {
        self.fileURL = fileURL
        self.maximumFileSize = maximumFileSize
    }

    func record(_ message: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let entry = "\(Self.timestamp()) \(message)\n"
        let entryData = Data(entry.utf8).prefix(maximumFileSize)
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let currentFileSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .intValue ?? 0
        if currentFileSize + entryData.count > maximumFileSize, fileManager.fileExists(atPath: fileURL.path) {
            try rotateCurrentLog(in: directoryURL)
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: entryData)
        } else {
            try Data(entryData).write(to: fileURL, options: .atomic)
        }
    }

    func copyableContents() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func rotateCurrentLog(in directoryURL: URL) throws {
        let timestamp = Self.timestamp().replacingOccurrences(of: ":", with: "-")
        var rotatedURL = directoryURL.appending(path: "diagnostics-\(timestamp).log")
        var sequence = 1
        while FileManager.default.fileExists(atPath: rotatedURL.path) {
            rotatedURL = directoryURL.appending(path: "diagnostics-\(timestamp)-\(sequence).log")
            sequence += 1
        }
        try FileManager.default.moveItem(at: fileURL, to: rotatedURL)
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appending(path: "MacICNS", directoryHint: .isDirectory)
            .appending(path: "diagnostics.log")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
