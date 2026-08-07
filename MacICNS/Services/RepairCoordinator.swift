import Foundation

actor RepairCoordinator {
    private let fingerprinting: any Fingerprinting
    private let locator: any ApplicationLocating
    private let applier: any IconApplying
    private var activeRepairs: [UUID: Task<IconMapping, Never>] = [:]

    init(
        fingerprinting: any Fingerprinting = BundleFingerprinting(),
        locator: any ApplicationLocating = ApplicationLocator(),
        applier: any IconApplying
    ) {
        self.fingerprinting = fingerprinting
        self.locator = locator
        self.applier = applier
    }

    func repair(_ mapping: IconMapping, reason: RepairReason) async -> IconMapping {
        if let activeRepair = activeRepairs[mapping.id] {
            return await activeRepair.value
        }

        let repair = Task { [self] in
            await performRepair(mapping, reason: reason)
        }
        activeRepairs[mapping.id] = repair

        let repairedMapping = await repair.value
        activeRepairs[mapping.id] = nil
        return repairedMapping
    }

    private func performRepair(_ mapping: IconMapping, reason _: RepairReason) async -> IconMapping {
        var repairedMapping = mapping

        guard let applicationURL = resolveApplicationURL(for: &repairedMapping) else {
            repairedMapping.status = .missingApp
            return repairedMapping
        }

        do {
            let appFingerprint = try fingerprinting.fingerprint(of: applicationURL)
            let iconFingerprint = try fingerprinting.fingerprint(of: repairedMapping.iconURL)

            guard appFingerprint != repairedMapping.appFingerprint
                || iconFingerprint != repairedMapping.iconFingerprint else {
                repairedMapping.status = .upToDate
                return repairedMapping
            }

            try await applier.apply(applicationURL: applicationURL, iconURL: repairedMapping.iconURL)
            repairedMapping.appFingerprint = appFingerprint
            repairedMapping.iconFingerprint = iconFingerprint
            repairedMapping.lastSuccessAt = Date()
            repairedMapping.status = .upToDate
        } catch {
            repairedMapping.status = isPermissionFailure(error) ? .needsPermission : .failed
        }

        return repairedMapping
    }

    private func resolveApplicationURL(for mapping: inout IconMapping) -> URL? {
        if FileManager.default.fileExists(atPath: mapping.applicationURL.path) {
            return mapping.applicationURL
        }

        guard let bundleIdentifier = mapping.bundleIdentifier,
              let locatedURL = locator.resolve(bundleIdentifier)
        else {
            return nil
        }

        mapping.applicationURL = locatedURL.standardizedFileURL
        return mapping.applicationURL
    }

    private func isPermissionFailure(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.Code.fileReadNoPermission.rawValue
                || nsError.code == CocoaError.Code.fileWriteNoPermission.rawValue
        }

        return nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == POSIXErrorCode.EACCES.rawValue || nsError.code == POSIXErrorCode.EPERM.rawValue)
    }
}
