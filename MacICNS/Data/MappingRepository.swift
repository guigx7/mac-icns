protocol MappingRepository: Sendable {
    func load() throws -> [IconMapping]
    func save(_ mappings: [IconMapping]) throws
}
