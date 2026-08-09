import AppKit
import Foundation

struct IconApplierRouter: IconApplying, Sendable {
    private let isApplicationWritable: @Sendable (URL) -> Bool
    private let direct: any IconApplying
    private let privileged: any IconApplying

    init(
        isApplicationWritable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isWritableFile(atPath: $0.path)
        },
        direct: any IconApplying = DirectIconApplier(),
        privileged: any IconApplying = PrivilegedHelperClient()
    ) {
        self.isApplicationWritable = isApplicationWritable
        self.direct = direct
        self.privileged = privileged
    }

    func apply(applicationURL: URL, iconURL: URL) async throws {
        let applier = isApplicationWritable(applicationURL) ? direct : privileged
        try await applier.apply(applicationURL: applicationURL, iconURL: iconURL)
    }

    func reset(applicationURL: URL) async throws {
        let applier = isApplicationWritable(applicationURL) ? direct : privileged
        try await applier.reset(applicationURL: applicationURL)
    }
}

struct DirectIconApplier: IconApplying, Sendable {
    enum InputError: Error, Equatable, Sendable {
        case invalidApplicationURL
        case invalidIconURL
    }

    private let isApplicationWritable: @Sendable (URL) -> Bool
    private let setIcon: @MainActor @Sendable (URL, URL) -> Bool
    private let resetIcon: @MainActor @Sendable (URL) async -> Bool

    init(
        isApplicationWritable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isWritableFile(atPath: $0.path)
        },
        setIcon: @escaping @MainActor @Sendable (URL, URL) -> Bool = { applicationURL, iconURL in
            guard let image = NSImage(contentsOf: iconURL) else {
                return false
            }
            return NSWorkspace.shared.setIcon(image, forFile: applicationURL.path, options: [])
        },
        resetIcon: @escaping @MainActor @Sendable (URL) async -> Bool = { applicationURL in
            NSWorkspace.shared.setIcon(nil, forFile: applicationURL.path, options: [])
        }
    ) {
        self.isApplicationWritable = isApplicationWritable
        self.setIcon = setIcon
        self.resetIcon = resetIcon
    }

    func apply(applicationURL: URL, iconURL: URL) async throws {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            throw InputError.invalidApplicationURL
        }
        guard iconURL.pathExtension.caseInsensitiveCompare("icns") == .orderedSame else {
            throw InputError.invalidIconURL
        }
        guard isApplicationWritable(applicationURL) else {
            throw CocoaError(.fileWriteNoPermission)
        }

        guard await setIcon(applicationURL, iconURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func reset(applicationURL: URL) async throws {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            throw InputError.invalidApplicationURL
        }
        guard isApplicationWritable(applicationURL) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard await resetIcon(applicationURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
