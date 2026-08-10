import Foundation

struct ApplicationCatalogEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let displayName: String
    let eligibility: ApplicationEligibility

    var id: URL { url }
}

struct ApplicationCatalog: Equatable, Sendable {
    private let allEntries: [ApplicationCatalogEntry]

    init(entries: [ApplicationCatalogEntry]) {
        allEntries = entries
    }

    func entries(searchText: String) -> [ApplicationCatalogEntry] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmedSearch.isEmpty
            ? allEntries
            : allEntries.filter { $0.displayName.localizedCaseInsensitiveContains(trimmedSearch) }

        return filtered.sorted { lhs, rhs in
            let lhsIsCompatible = lhs.eligibility == .compatible
            let rhsIsCompatible = rhs.eligibility == .compatible
            if lhsIsCompatible != rhsIsCompatible {
                return lhsIsCompatible
            }

            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path) == .orderedAscending
        }
    }
}

struct ApplicationCatalogLoader: Sendable {
    typealias DirectoryContents = @Sendable (URL) throws -> [URL]
    typealias Resolve = @Sendable (URL) -> URL
    typealias DisplayName = @Sendable (URL) -> String

    private let roots: [URL]
    private let eligibility: any ApplicationEligibilityChecking
    private let directoryContents: DirectoryContents
    private let resolve: Resolve
    private let displayName: DisplayName

    init(
        roots: [URL] = Self.defaultRoots,
        eligibility: any ApplicationEligibilityChecking = ApplicationEligibilityService(),
        directoryContents: @escaping DirectoryContents = Self.contentsOfDirectory,
        resolve: @escaping Resolve = { $0.resolvingSymlinksInPath().standardizedFileURL },
        displayName: @escaping DisplayName = Self.applicationDisplayName
    ) {
        self.roots = roots
        self.eligibility = eligibility
        self.directoryContents = directoryContents
        self.resolve = resolve
        self.displayName = displayName
    }

    func load() -> ApplicationCatalog {
        var seenURLs = Set<URL>()
        var entries: [ApplicationCatalogEntry] = []

        for root in roots {
            guard let children = try? directoryContents(root) else {
                continue
            }
            for child in children where Self.isApplication(child) {
                let resolvedURL = resolve(child).standardizedFileURL
                guard seenURLs.insert(resolvedURL).inserted,
                      let entry = entry(forResolvedURL: resolvedURL) else {
                    continue
                }
                entries.append(entry)
            }
        }

        return ApplicationCatalog(entries: entries)
    }

    func entry(for applicationURL: URL) -> ApplicationCatalogEntry? {
        guard Self.isApplication(applicationURL) else {
            return nil
        }
        return entry(forResolvedURL: resolve(applicationURL).standardizedFileURL)
    }

    private func entry(forResolvedURL applicationURL: URL) -> ApplicationCatalogEntry? {
        guard Self.isApplication(applicationURL) else {
            return nil
        }
        return ApplicationCatalogEntry(
            url: applicationURL,
            displayName: displayName(applicationURL),
            eligibility: eligibility.eligibility(for: applicationURL)
        )
    }

    private static var defaultRoots: [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
        ]
    }

    private static func contentsOfDirectory(_ directoryURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    private static func applicationDisplayName(_ applicationURL: URL) -> String {
        if let bundle = Bundle(url: applicationURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !displayName.isEmpty {
                return displayName
            }
            if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !bundleName.isEmpty {
                return bundleName
            }
        }
        return applicationURL.deletingPathExtension().lastPathComponent
    }

    private static func isApplication(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }
}
