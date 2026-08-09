import AppKit
import Darwin
import Foundation

struct PrivilegedIconOperation {
    private let requiredOwnerUID: uid_t
    private let writer: StableApplicationIconWriter
    private let imageReader: (URL) throws -> NSImage
    private let notifyFileSystemChanged: (URL) -> Void

    init(
        requiredOwnerUID: uid_t = 0,
        writer: StableApplicationIconWriter = StableApplicationIconWriter(),
        imageReader: @escaping (URL) throws -> NSImage = IconDataReader.image,
        notifyFileSystemChanged: @escaping (URL) -> Void = {
            NSWorkspace.shared.noteFileSystemChanged($0.path)
        }
    ) {
        self.requiredOwnerUID = requiredOwnerUID
        self.writer = writer
        self.imageReader = imageReader
        self.notifyFileSystemChanged = notifyFileSystemChanged
    }

    func apply(request: IconApplyRequest) throws {
        let applicationDescriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: request.applicationURL,
            requiredOwnerUID: requiredOwnerUID
        )
        defer { close(applicationDescriptor) }

        let image = try imageReader(request.iconURL)
        try writer.apply(image: image, toApplicationDescriptor: applicationDescriptor)
        notifyFileSystemChanged(request.applicationURL)
    }

    func reset(request: IconResetRequest) throws {
        let applicationDescriptor = try PrivilegedPathValidator.openApplicationDirectory(
            applicationURL: request.applicationURL,
            requiredOwnerUID: requiredOwnerUID
        )
        defer { close(applicationDescriptor) }

        try writer.reset(applicationDescriptor: applicationDescriptor)
        notifyFileSystemChanged(request.applicationURL)
    }
}
