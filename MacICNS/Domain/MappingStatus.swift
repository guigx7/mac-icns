enum MappingStatus: String, Codable, Equatable, Sendable {
    case upToDate
    case needsPermission
    case missingApp
    case failed
}
