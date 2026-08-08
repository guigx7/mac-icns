import AppKit
import Darwin
import Foundation

enum IconDataReader {
    enum ReadError: Error, Equatable, Sendable {
        case unsafePath
        case invalidIcon
        case iconIsTooLarge
    }

    /// A custom icon should be small; 64 MiB leaves generous room for valid ICNS assets
    /// while preventing a privileged helper from allocating unbounded client-controlled data.
    static let maximumIconByteCount: off_t = 64 * 1024 * 1024

    static func image(at url: URL) throws -> NSImage {
        let descriptor = try openWithoutFollowingLinks(at: url.standardizedFileURL)
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ReadError.unsafePath
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw ReadError.unsafePath
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumIconByteCount else {
            throw ReadError.iconIsTooLarge
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Int(maximumIconByteCount) + 1) ?? Data()
        guard data.count <= Int(maximumIconByteCount) else {
            throw ReadError.iconIsTooLarge
        }
        guard let image = NSImage(data: data) else {
            throw ReadError.invalidIcon
        }
        return image
    }

    static func openWithoutFollowingLinks(at url: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ReadError.unsafePath
        }

        let components = Array(url.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            let isLeaf = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isLeaf ? O_NONBLOCK : O_DIRECTORY)
            let nextDescriptor = openat(descriptor, component, flags)
            close(descriptor)
            guard nextDescriptor >= 0 else {
                throw ReadError.unsafePath
            }
            descriptor = nextDescriptor
        }
        return descriptor
    }
}
