import Foundation

struct IconMapping: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var applicationURL: URL
    var bundleIdentifier: String?
    var iconURL: URL
    var appFingerprint: String?
    var iconFingerprint: String?
    var lastSuccessAt: Date?
    var status: MappingStatus

    init(applicationURL: URL, bundleIdentifier: String?, iconURL: URL) {
        self.id = UUID()
        self.applicationURL = applicationURL.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.iconURL = iconURL.standardizedFileURL
        appFingerprint = nil
        iconFingerprint = nil
        lastSuccessAt = nil
        status = .upToDate
    }
}
