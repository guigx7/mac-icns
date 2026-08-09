import Foundation

struct RepairFailureDetails: Equatable, Sendable {
    enum Category: Equatable, Sendable {
        case helperUnavailable
        case unsafeTarget
        case metadataWrite
        case other
    }

    let operation: String
    let category: Category
    let domain: String
    let code: Int
    let description: String

    var userMessage: String {
        switch category {
        case .helperUnavailable:
            "The privileged helper is unavailable. Update or approve it in Settings."
        case .unsafeTarget:
            "The application path is not safe for privileged icon changes."
        case .metadataWrite:
            "The helper reached the application but could not write Finder icon metadata."
        case .other:
            "The icon operation failed. Review Settings and try again."
        }
    }

    var diagnosticSummary: String {
        "operation=\(operation) domain=\(domain) code=\(code) description=\(description)"
    }
}

actor RepairCoordinator {
    private let fingerprinting: any Fingerprinting
    private let locator: any ApplicationLocating
    private let applier: any IconApplying
    private var activeRepairs: [UUID: Task<IconMapping, Never>] = [:]
    private var mappingsByID: [UUID: IconMapping] = [:]
    private var mappingOrder: [UUID] = []
    private var failureDetailsByID: [UUID: RepairFailureDetails] = [:]

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
        mappingsByID[repairedMapping.id] = repairedMapping
        return repairedMapping
    }

    func setEnabled(_ isEnabled: Bool, for mapping: IconMapping) async -> IconMapping {
        if let activeRepair = activeRepairs[mapping.id] {
            _ = await activeRepair.value
            activeRepairs[mapping.id] = nil
        }

        if isEnabled {
            guard !mapping.isEnabled else {
                return mapping
            }
            var candidate = mapping
            candidate.isEnabled = true
            candidate.appFingerprint = nil
            candidate.iconFingerprint = nil
            let repaired = await repair(candidate, reason: .mappingEdited)
            guard repaired.status == .upToDate else {
                var unchanged = mapping
                unchanged.status = repaired.status
                return unchanged
            }
            return repaired
        }

        guard mapping.isEnabled else {
            return mapping
        }
        var updated = mapping
        guard let applicationURL = resolveApplicationURL(for: &updated) else {
            updated.status = .missingApp
            return updated
        }
        do {
            try await applier.reset(applicationURL: applicationURL)
            updated.isEnabled = false
            updated.appFingerprint = nil
            updated.iconFingerprint = nil
            updated.lastSuccessAt = nil
            updated.status = .upToDate
            failureDetailsByID[mapping.id] = nil
        } catch {
            updated.status = isPermissionFailure(error) ? .needsPermission : .failed
            failureDetailsByID[mapping.id] = makeFailureDetails(
                error: error,
                operation: "reset",
                mapping: updated
            )
        }
        return updated
    }

    func resetForRemoval(_ mapping: IconMapping) async throws {
        if let activeRepair = activeRepairs[mapping.id] {
            _ = await activeRepair.value
            activeRepairs[mapping.id] = nil
        }
        var resolvedMapping = mapping
        guard let applicationURL = resolveApplicationURL(for: &resolvedMapping) else {
            throw CocoaError(.fileNoSuchFile)
        }
        do {
            try await applier.reset(applicationURL: applicationURL)
            failureDetailsByID[mapping.id] = nil
        } catch {
            failureDetailsByID[mapping.id] = makeFailureDetails(
                error: error,
                operation: "reset",
                mapping: resolvedMapping
            )
            throw error
        }
    }

    func setMappings(_ mappings: [IconMapping]) {
        mappingsByID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.id, $0) })
        mappingOrder = mappings.map(\.id)
        failureDetailsByID = failureDetailsByID.filter { mappingsByID[$0.key] != nil }
    }

    func failureDetails(for mappingID: UUID) -> RepairFailureDetails? {
        failureDetailsByID[mappingID]
    }

    func repairAll(reason: RepairReason) async -> [IconMapping] {
        let mappings = mappingOrder.compactMap { mappingsByID[$0] }
        return await repairAll(mappings, reason: reason)
    }

    func repairAll(_ mappings: [IconMapping], reason: RepairReason) async -> [IconMapping] {
        setMappings(mappings)
        return await withTaskGroup(of: (Int, IconMapping).self, returning: [IconMapping].self) { group in
            for (index, mapping) in mappings.enumerated() {
                group.addTask {
                    (index, await self.repair(mapping, reason: reason))
                }
            }

            var repairedMappings = mappings
            for await (index, repairedMapping) in group {
                repairedMappings[index] = repairedMapping
            }
            setMappings(repairedMappings)
            return repairedMappings
        }
    }

    private func performRepair(_ mapping: IconMapping, reason: RepairReason) async -> IconMapping {
        var repairedMapping = mapping

        guard repairedMapping.isEnabled else {
            failureDetailsByID[mapping.id] = nil
            return repairedMapping
        }

        guard let applicationURL = resolveApplicationURL(for: &repairedMapping) else {
            repairedMapping.status = .missingApp
            failureDetailsByID[mapping.id] = nil
            return repairedMapping
        }

        do {
            let appFingerprint = try fingerprinting.fingerprint(of: applicationURL)
            let iconFingerprint = try fingerprinting.fingerprint(of: repairedMapping.iconURL)

            guard reason == .helperUpdated
                || appFingerprint != repairedMapping.appFingerprint
                || iconFingerprint != repairedMapping.iconFingerprint else {
                repairedMapping.status = .upToDate
                failureDetailsByID[mapping.id] = nil
                return repairedMapping
            }

            try await applier.apply(applicationURL: applicationURL, iconURL: repairedMapping.iconURL)
            repairedMapping.appFingerprint = appFingerprint
            repairedMapping.iconFingerprint = iconFingerprint
            repairedMapping.lastSuccessAt = Date()
            repairedMapping.status = .upToDate
            failureDetailsByID[mapping.id] = nil
        } catch {
            repairedMapping.status = isPermissionFailure(error) ? .needsPermission : .failed
            failureDetailsByID[mapping.id] = makeFailureDetails(
                error: error,
                operation: "apply",
                mapping: repairedMapping
            )
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

    private func makeFailureDetails(
        error: Error,
        operation: String,
        mapping: IconMapping
    ) -> RepairFailureDetails {
        let nsError = error as NSError
        var description = nsError.localizedDescription
        for (path, replacement) in [
            (mapping.applicationURL.path, "<application>"),
            (mapping.iconURL.path, "<icon>"),
        ] where !path.isEmpty {
            description = description.replacingOccurrences(of: path, with: replacement)
        }
        description = description
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        description = String(description.prefix(300))

        return RepairFailureDetails(
            operation: operation,
            category: failureCategory(error: error, nsError: nsError),
            domain: String(nsError.domain.prefix(200)),
            code: nsError.code,
            description: description
        )
    }

    private func failureCategory(error: Error, nsError: NSError) -> RepairFailureDetails.Category {
        if isPermissionFailure(error) {
            return .helperUnavailable
        }
        if error is PrivilegedPathValidator.ValidationError
            || nsError.domain.contains("PrivilegedPathValidator") {
            return .unsafeTarget
        }
        if error is StableApplicationIconWriter.WriteError
            || nsError.domain.contains("StableApplicationIconWriter") {
            return .metadataWrite
        }
        if nsError.domain == "com.guigx.macicns.helper" {
            return .metadataWrite
        }
        return .other
    }
}
