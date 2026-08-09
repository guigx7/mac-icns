import Foundation

enum RepairReason: Sendable {
    case launch
    case login
    case manual
    case fileSystemChange
    case mappingEdited
    case helperUpdated
}

protocol Fingerprinting: Sendable {
    func fingerprint(of url: URL) throws -> String
}

protocol ApplicationLocating: Sendable {
    func resolve(_ bundleIdentifier: String) -> URL?
}

protocol IconApplying: Sendable {
    func apply(applicationURL: URL, iconURL: URL) async throws
    func reset(applicationURL: URL) async throws
}
