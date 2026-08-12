import Foundation

struct RepairFailureDetails: Equatable, Sendable {
    enum Category: Equatable, Sendable {
        case permission
        case other
    }

    let operation: String
    let category: Category
    let domain: String
    let code: Int
    let description: String

    var userMessage: String {
        switch category {
        case .permission:
            "The application is no longer writable."
        case .other:
            "The icon operation failed. Review Settings and try again."
        }
    }

    var diagnosticSummary: String {
        "operation=\(operation) domain=\(domain) code=\(code) description=\(description)"
    }
}

actor RepairCoordinator {
    private struct ActiveRepair {
        let token: UUID
        let task: Task<IconMapping, Never>
        let includesManualRepair: Bool
    }

    private let fingerprinting: any Fingerprinting
    private let locator: any ApplicationLocating
    private let applicationRunningChecker: any ApplicationRunningChecking
    private let applier: any IconApplying
    private var activeRepairs: [UUID: ActiveRepair] = [:]
    private var mappingsByID: [UUID: IconMapping] = [:]
    private var mappingOrder: [UUID] = []
    private var failureDetailsByID: [UUID: RepairFailureDetails] = [:]

    init(
        fingerprinting: any Fingerprinting = BundleFingerprinting(),
        locator: any ApplicationLocating = ApplicationLocator(),
        applicationRunningChecker: any ApplicationRunningChecking = WorkspaceApplicationRuntime.shared,
        applier: any IconApplying
    ) {
        self.fingerprinting = fingerprinting
        self.locator = locator
        self.applicationRunningChecker = applicationRunningChecker
        self.applier = applier
    }

    func repair(_ mapping: IconMapping, reason: RepairReason) async -> IconMapping {
        if let activeRepair = activeRepairs[mapping.id] {
            if reason == .manual, !activeRepair.includesManualRepair {
                let token = UUID()
                let repair = Task { [self] in
                    _ = await activeRepair.task.value
                    return await performRepair(mapping, reason: .manual)
                }
                let manualFollowUp = ActiveRepair(
                    token: token,
                    task: repair,
                    includesManualRepair: true
                )
                activeRepairs[mapping.id] = manualFollowUp
                return await finish(manualFollowUp, mappingID: mapping.id)
            }
            return await finish(activeRepair, mappingID: mapping.id)
        }

        let token = UUID()
        let repair = Task { [self] in
            await performRepair(mapping, reason: reason)
        }
        let activeRepair = ActiveRepair(
            token: token,
            task: repair,
            includesManualRepair: reason == .manual
        )
        activeRepairs[mapping.id] = activeRepair
        return await finish(activeRepair, mappingID: mapping.id)
    }

    func setEnabled(_ isEnabled: Bool, for mapping: IconMapping) async -> IconMapping {
        await finishActiveRepairs(for: mapping.id)

        if isEnabled {
            guard !mapping.isEnabled else {
                return mapping
            }
            var candidate = mapping
            candidate.isEnabled = true
            candidate.appFingerprint = nil
            candidate.iconFingerprint = nil
            let repaired = await repair(candidate, reason: .mappingEdited)
            guard repaired.status.isSuccessful else {
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
        await finishActiveRepairs(for: mapping.id)
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

    private func finish(_ activeRepair: ActiveRepair, mappingID: UUID) async -> IconMapping {
        let repairedMapping = await activeRepair.task.value
        if activeRepairs[mappingID]?.token == activeRepair.token {
            activeRepairs[mappingID] = nil
            mappingsByID[repairedMapping.id] = repairedMapping
        }
        return repairedMapping
    }

    private func finishActiveRepairs(for mappingID: UUID) async {
        while let activeRepair = activeRepairs[mappingID] {
            _ = await finish(activeRepair, mappingID: mappingID)
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

            let fingerprintsChanged = appFingerprint != repairedMapping.appFingerprint
                || iconFingerprint != repairedMapping.iconFingerprint

            if !fingerprintsChanged, reason != .manual {
                if repairedMapping.status == .restartRequired,
                   let bundleIdentifier = repairedMapping.bundleIdentifier {
                    repairedMapping.status = await applicationRunningChecker.isRunning(
                        bundleIdentifier: bundleIdentifier
                    ) ? .restartRequired : .upToDate
                } else {
                    repairedMapping.status = .upToDate
                }
                failureDetailsByID[mapping.id] = nil
                return repairedMapping
            }

            try await applier.apply(applicationURL: applicationURL, iconURL: repairedMapping.iconURL)
            repairedMapping.appFingerprint = appFingerprint
            repairedMapping.iconFingerprint = iconFingerprint
            repairedMapping.lastSuccessAt = Date()
            if let bundleIdentifier = repairedMapping.bundleIdentifier,
               await applicationRunningChecker.isRunning(bundleIdentifier: bundleIdentifier) {
                repairedMapping.status = .restartRequired
            } else {
                repairedMapping.status = .upToDate
            }
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
            return .permission
        }
        return .other
    }
}
