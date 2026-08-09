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
    var isEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case applicationURL
        case bundleIdentifier
        case iconURL
        case appFingerprint
        case iconFingerprint
        case lastSuccessAt
        case status
        case isEnabled
    }

    init(applicationURL: URL, bundleIdentifier: String?, iconURL: URL) {
        self.id = UUID()
        self.applicationURL = applicationURL.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.iconURL = iconURL.standardizedFileURL
        appFingerprint = nil
        iconFingerprint = nil
        lastSuccessAt = nil
        status = .upToDate
        isEnabled = true
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        applicationURL = try container.decode(URL.self, forKey: .applicationURL).standardizedFileURL
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        iconURL = try container.decode(URL.self, forKey: .iconURL).standardizedFileURL
        appFingerprint = try container.decodeIfPresent(String.self, forKey: .appFingerprint)
        iconFingerprint = try container.decodeIfPresent(String.self, forKey: .iconFingerprint)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        status = try container.decode(MappingStatus.self, forKey: .status)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(applicationURL, forKey: .applicationURL)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(iconURL, forKey: .iconURL)
        try container.encodeIfPresent(appFingerprint, forKey: .appFingerprint)
        try container.encodeIfPresent(iconFingerprint, forKey: .iconFingerprint)
        try container.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAt)
        try container.encode(status, forKey: .status)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}
