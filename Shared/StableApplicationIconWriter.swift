import AppKit
import Darwin
import Foundation

struct FinderIconMetadata: Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidResourceFork
        case invalidFinderInfo
    }

    static let maximumResourceForkByteCount = 64 * 1024 * 1024
    static let finderInfoByteCount = 32

    let resourceFork: Data
    let iconFinderInfo: Data

    init(resourceFork: Data, iconFinderInfo: Data) throws {
        guard !resourceFork.isEmpty,
              resourceFork.count <= Self.maximumResourceForkByteCount
        else {
            throw ValidationError.invalidResourceFork
        }
        guard iconFinderInfo.count == Self.finderInfoByteCount else {
            throw ValidationError.invalidFinderInfo
        }
        self.resourceFork = resourceFork
        self.iconFinderInfo = iconFinderInfo
    }
}

struct StableApplicationIconWriter {
    enum WriteError: LocalizedError, Sendable {
        case stagingFailed
        case unsafeIconMetadata
        case missingIconMetadata
        case metadataTooLarge
        case systemCall(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .stagingFailed:
                "Could not generate trusted Finder icon metadata."
            case .unsafeIconMetadata:
                "The Finder icon metadata target is unsafe."
            case .missingIconMetadata:
                "Finder did not generate the required icon metadata."
            case .metadataTooLarge:
                "Finder icon metadata exceeds the safe size limit."
            case let .systemCall(operation, code):
                "Finder icon metadata operation \(operation) failed (POSIX \(code))."
            }
        }

        var xpcError: NSError {
            switch self {
            case let .systemCall(operation, code):
                let reason = String(cString: strerror(code))
                return NSError(
                    domain: "com.guigx.macicns.helper.icon-write",
                    code: Int(code),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Finder icon metadata operation \(operation) failed "
                            + "(POSIX \(code): \(reason))."
                    ]
                )
            default:
                return NSError(
                    domain: "com.guigx.macicns.helper.icon-write",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: errorDescription ?? "The icon could not be written."]
                )
            }
        }
    }

    private static let iconFileName = "Icon\r"
    private static let finderInfoName = "com.apple.FinderInfo"
    private static let resourceForkName = "com.apple.ResourceFork"
    private static let customIconFlag: UInt16 = 0x0400

    @MainActor
    func prepareMetadata(for image: NSImage) throws -> FinderIconMetadata {
        let stagingDirectory = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(path: "MacICNS-IconMetadata-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        guard chmod(stagingDirectory.path, 0o700) == 0 else {
            throw posixError("chmod staging directory")
        }

        let stagingApplication = stagingDirectory.appending(path: "Metadata.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingApplication,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard NSWorkspace.shared.setIcon(image, forFile: stagingApplication.path, options: []) else {
            throw WriteError.stagingFailed
        }

        let stagingApplicationDescriptor = open(
            stagingApplication.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard stagingApplicationDescriptor >= 0 else {
            throw posixError("open staging application")
        }
        defer { close(stagingApplicationDescriptor) }

        let stagingIconDescriptor = openat(
            stagingApplicationDescriptor,
            Self.iconFileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard stagingIconDescriptor >= 0 else {
            throw WriteError.missingIconMetadata
        }
        defer { close(stagingIconDescriptor) }
        try requireRegularFile(descriptor: stagingIconDescriptor)

        guard let resourceFork = try readExtendedAttribute(
            Self.resourceForkName,
            descriptor: stagingIconDescriptor,
            maximumByteCount: FinderIconMetadata.maximumResourceForkByteCount
        ), !resourceFork.isEmpty,
        let iconFinderInfo = try readExtendedAttribute(
            Self.finderInfoName,
            descriptor: stagingIconDescriptor,
            maximumByteCount: FinderIconMetadata.finderInfoByteCount
        ) else {
            throw WriteError.missingIconMetadata
        }

        return try FinderIconMetadata(
            resourceFork: resourceFork,
            iconFinderInfo: iconFinderInfo
        )
    }

    @MainActor
    func apply(image: NSImage, toApplicationDescriptor descriptor: Int32) throws {
        try apply(
            metadata: prepareMetadata(for: image),
            toApplicationDescriptor: descriptor
        )
    }

    func apply(
        metadata: FinderIconMetadata,
        toApplicationDescriptor descriptor: Int32
    ) throws {
        let validatedMetadata = try FinderIconMetadata(
            resourceFork: metadata.resourceFork,
            iconFinderInfo: metadata.iconFinderInfo
        )

        let targetIconDescriptor = openat(
            descriptor,
            Self.iconFileName,
            O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard targetIconDescriptor >= 0 else {
            if errno == ELOOP {
                throw WriteError.unsafeIconMetadata
            }
            throw posixError("create target icon metadata")
        }
        defer { close(targetIconDescriptor) }
        try requireSafeTargetIcon(
            descriptor: targetIconDescriptor,
            applicationDescriptor: descriptor
        )
        guard fchmod(targetIconDescriptor, 0o600) == 0,
              ftruncate(targetIconDescriptor, 0) == 0
        else {
            throw posixError("prepare target icon metadata")
        }

        try writeExtendedAttribute(
            Self.resourceForkName,
            data: validatedMetadata.resourceFork,
            descriptor: targetIconDescriptor
        )
        try writeExtendedAttribute(
            Self.finderInfoName,
            data: validatedMetadata.iconFinderInfo,
            descriptor: targetIconDescriptor
        )
        try updateFinderFlags(descriptor: descriptor) { $0 | Self.customIconFlag }
    }

    func reset(applicationDescriptor descriptor: Int32) throws {
        if unlinkat(descriptor, Self.iconFileName, 0) != 0, errno != ENOENT {
            throw posixError("remove target icon metadata")
        }
        try updateFinderFlags(descriptor: descriptor, createIfMissing: false) {
            $0 & ~Self.customIconFlag
        }
    }

    private func requireRegularFile(descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG
        else {
            throw WriteError.unsafeIconMetadata
        }
    }

    private func requireSafeTargetIcon(
        descriptor: Int32,
        applicationDescriptor: Int32
    ) throws {
        var iconMetadata = stat()
        var applicationMetadata = stat()
        guard fstat(descriptor, &iconMetadata) == 0,
              fstat(applicationDescriptor, &applicationMetadata) == 0,
              (iconMetadata.st_mode & S_IFMT) == S_IFREG,
              iconMetadata.st_uid == applicationMetadata.st_uid,
              iconMetadata.st_nlink == 1,
              (iconMetadata.st_mode & (S_IWGRP | S_IWOTH)) == 0
        else {
            throw WriteError.unsafeIconMetadata
        }
    }

    private func updateFinderFlags(
        descriptor: Int32,
        createIfMissing: Bool = true,
        transform: (UInt16) -> UInt16
    ) throws {
        let existing = try readExtendedAttribute(
            Self.finderInfoName,
            descriptor: descriptor,
            maximumByteCount: FinderIconMetadata.finderInfoByteCount
        )
        guard existing != nil || createIfMissing else { return }

        var finderInfo = [UInt8](
            existing ?? Data(repeating: 0, count: FinderIconMetadata.finderInfoByteCount)
        )
        guard finderInfo.count == FinderIconMetadata.finderInfoByteCount else {
            throw WriteError.unsafeIconMetadata
        }
        let flags = UInt16(finderInfo[8]) << 8 | UInt16(finderInfo[9])
        let updatedFlags = transform(flags)
        finderInfo[8] = UInt8(updatedFlags >> 8)
        finderInfo[9] = UInt8(updatedFlags & 0x00ff)

        if finderInfo.allSatisfy({ $0 == 0 }) {
            if Self.finderInfoName.withCString({ fremovexattr(descriptor, $0, 0) }) != 0,
               errno != ENOATTR {
                throw posixError("remove FinderInfo")
            }
        } else {
            try writeExtendedAttribute(
                Self.finderInfoName,
                data: Data(finderInfo),
                descriptor: descriptor
            )
        }
    }

    private func readExtendedAttribute(
        _ name: String,
        descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data? {
        errno = 0
        let byteCount = name.withCString { fgetxattr(descriptor, $0, nil, 0, 0, 0) }
        if byteCount < 0 {
            if errno == ENOATTR { return nil }
            throw posixError("read \(name) size")
        }
        guard byteCount <= maximumByteCount else {
            throw WriteError.metadataTooLarge
        }

        var data = Data(count: byteCount)
        let readByteCount = data.withUnsafeMutableBytes { buffer in
            name.withCString {
                fgetxattr(descriptor, $0, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard readByteCount == byteCount else {
            throw posixError("read \(name)")
        }
        return data
    }

    private func writeExtendedAttribute(
        _ name: String,
        data: Data,
        descriptor: Int32
    ) throws {
        let result = data.withUnsafeBytes { buffer in
            name.withCString {
                fsetxattr(descriptor, $0, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard result == 0 else {
            throw posixError("write \(name)")
        }
    }

    private func posixError(_ operation: String) -> WriteError {
        WriteError.systemCall(operation: operation, code: errno)
    }
}
