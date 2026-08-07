import CryptoKit
import Foundation

struct BundleFingerprinting: Fingerprinting {
    func fingerprint(of url: URL) throws -> String {
        if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return try bundleFingerprint(of: url)
        }

        return try iconFingerprint(of: url)
    }

    private func bundleFingerprint(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try requiredModificationDate(from: attributes)
        let fileSize = try requiredFileSize(from: attributes)
        let version = bundleVersion(at: url)

        return "\(modificationDate.timeIntervalSince1970.bitPattern):\(fileSize):\(version)"
    }

    private func iconFingerprint(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func requiredModificationDate(from attributes: [FileAttributeKey: Any]) throws -> Date {
        guard let modificationDate = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }

        return modificationDate
    }

    private func requiredFileSize(from attributes: [FileAttributeKey: Any]) throws -> Int64 {
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }

        return fileSize.int64Value
    }

    private func bundleVersion(at url: URL) -> String {
        guard let bundle = Bundle(url: url) else {
            return "unknown"
        }

        return (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "unknown"
    }
}
