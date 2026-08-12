enum MappingStatus: String, Codable, Equatable, Sendable {
    case upToDate
    case restartRequired
    case needsPermission
    case missingApp
    case failed
}

extension MappingStatus {
    var isSuccessful: Bool {
        self == .upToDate || self == .restartRequired
    }
}
