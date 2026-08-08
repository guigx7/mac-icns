import AppKit
import Darwin
import Foundation

enum IconDataReader {
    enum ReadError: Error {
        case unsafePath
        case invalidIcon
    }

    static func image(at url: URL) throws -> NSImage {
        let descriptor = try openRegularFileWithoutFollowingLinks(at: url.standardizedFileURL)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        guard let image = NSImage(data: data) else {
            throw ReadError.invalidIcon
        }
        return image
    }

    private static func openRegularFileWithoutFollowingLinks(at url: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ReadError.unsafePath
        }

        for component in url.pathComponents.dropFirst() {
            let nextDescriptor = openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard nextDescriptor >= 0 else {
                throw ReadError.unsafePath
            }
            descriptor = nextDescriptor
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw ReadError.unsafePath
        }
        return descriptor
    }
}
