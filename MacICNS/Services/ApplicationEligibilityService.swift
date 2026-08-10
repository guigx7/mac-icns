import Foundation

enum ApplicationEligibility: Equatable, Sendable {
    case compatible
    case protected
    case systemApplication
    case missing
    case invalid
}

protocol ApplicationEligibilityChecking: Sendable {
    func eligibility(for applicationURL: URL) -> ApplicationEligibility
}

struct ApplicationInspection: Sendable {
    let resolvedURL: URL
    let exists: Bool
    let isDirectory: Bool
    let volumeIsReadOnly: Bool
    let isWritable: Bool
}

struct ApplicationEligibilityService: ApplicationEligibilityChecking, Sendable {
    typealias Inspect = @Sendable (URL) throws -> ApplicationInspection

    private let inspect: Inspect

    init() {
        inspect = Self.inspectApplication
    }

    init(inspect: @escaping Inspect) {
        self.inspect = inspect
    }

    func eligibility(for applicationURL: URL) -> ApplicationEligibility {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return .invalid
        }

        let inspection: ApplicationInspection
        do {
            inspection = try inspect(applicationURL)
        } catch {
            return .invalid
        }

        guard inspection.exists else {
            return .missing
        }
        guard inspection.isDirectory,
              inspection.resolvedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return .invalid
        }
        if Self.isSystemApplication(inspection.resolvedURL) {
            return .systemApplication
        }
        guard !inspection.volumeIsReadOnly, inspection.isWritable else {
            return .protected
        }
        return .compatible
    }

    private static func inspectApplication(_ applicationURL: URL) throws -> ApplicationInspection {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(
            atPath: applicationURL.path,
            isDirectory: &isDirectory
        )

        guard exists else {
            if (try? fileManager.destinationOfSymbolicLink(atPath: applicationURL.path)) != nil {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return ApplicationInspection(
                resolvedURL: applicationURL,
                exists: false,
                isDirectory: false,
                volumeIsReadOnly: false,
                isWritable: false
            )
        }

        let resolvedURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        var resolvedIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: resolvedURL.path,
            isDirectory: &resolvedIsDirectory
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let resourceValues = try resolvedURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])

        return ApplicationInspection(
            resolvedURL: resolvedURL,
            exists: true,
            isDirectory: resolvedIsDirectory.boolValue,
            volumeIsReadOnly: resourceValues.volumeIsReadOnly ?? false,
            isWritable: fileManager.isWritableFile(atPath: resolvedURL.path)
        )
    }

    private static func isSystemApplication(_ applicationURL: URL) -> Bool {
        let path = applicationURL.standardizedFileURL.path
        return pathIsInside(path, directory: "/System/Applications")
            || pathIsInside(path, directory: "/System/Library/CoreServices")
    }

    private static func pathIsInside(_ path: String, directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }
}
