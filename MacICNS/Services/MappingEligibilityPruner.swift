import Foundation

struct MappingEligibilityPruner: Sendable {
    private let eligibility: any ApplicationEligibilityChecking
    private let locator: any ApplicationLocating

    init(
        eligibility: any ApplicationEligibilityChecking = ApplicationEligibilityService(),
        locator: any ApplicationLocating = ApplicationLocator()
    ) {
        self.eligibility = eligibility
        self.locator = locator
    }

    func prune(_ mappings: [IconMapping]) -> [IconMapping] {
        mappings.compactMap(prune)
    }

    func acceptsNewMapping(_ mapping: IconMapping) -> Bool {
        eligibility.eligibility(for: mapping.applicationURL) == .compatible
    }

    private func prune(_ mapping: IconMapping) -> IconMapping? {
        switch eligibility.eligibility(for: mapping.applicationURL) {
        case .compatible:
            return mapping
        case .protected, .systemApplication, .invalid:
            return nil
        case .missing:
            return resolveMissing(mapping)
        }
    }

    private func resolveMissing(_ mapping: IconMapping) -> IconMapping? {
        guard let bundleIdentifier = mapping.bundleIdentifier,
              let locatedURL = locator.resolve(bundleIdentifier)?.standardizedFileURL else {
            return mapping
        }

        switch eligibility.eligibility(for: locatedURL) {
        case .compatible:
            var relocated = mapping
            relocated.applicationURL = locatedURL
            relocated.appFingerprint = nil
            return relocated
        case .missing:
            return mapping
        case .protected, .systemApplication, .invalid:
            return nil
        }
    }
}
