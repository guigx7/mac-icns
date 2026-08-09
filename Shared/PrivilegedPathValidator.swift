import Darwin
import Foundation

enum PrivilegedPathValidator {
    enum ValidationError: Error, Equatable, Sendable {
        case targetIsMutableByUnprivilegedUser
        case unsafePath
    }

    static func validate(applicationURL: URL) throws {
        let descriptor = try openApplicationDirectory(applicationURL: applicationURL)
        close(descriptor)
    }

    /// Returns an owned descriptor for a validated application directory. The caller
    /// must close it. Walking from an already-open parent means mutable ancestors cannot
    /// redirect later component lookups.
    static func openApplicationDirectory(
        applicationURL: URL,
        requiredOwnerUID: uid_t = 0
    ) throws -> Int32 {
        let path = applicationURL.path
        let pathComponents = (path as NSString).pathComponents
        guard applicationURL.isFileURL,
              path.hasPrefix("/"),
              (path as NSString).pathExtension.lowercased() == "app",
              !pathComponents.contains("."),
              !pathComponents.contains("..")
        else {
            throw ValidationError.unsafePath
        }

        var currentDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentDescriptor >= 0 else {
            throw ValidationError.unsafePath
        }

        do {
            for component in pathComponents.dropFirst() {
                let nextDescriptor = openat(
                    currentDescriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard nextDescriptor >= 0 else {
                    throw ValidationError.unsafePath
                }

                close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }

            var metadata = stat()
            guard fstat(currentDescriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR
            else {
                throw ValidationError.unsafePath
            }

            guard metadata.st_uid == requiredOwnerUID,
                  (metadata.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  !hasExtendedACL(descriptor: currentDescriptor)
            else {
                throw ValidationError.targetIsMutableByUnprivilegedUser
            }

            return currentDescriptor
        } catch {
            close(currentDescriptor)
            throw error
        }
    }

    private static func hasExtendedACL(descriptor: Int32) -> Bool {
        errno = 0
        guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno != ENOENT && errno != ENOATTR
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }

        var entry: acl_entry_t?
        return acl_get_entry(
            accessControlList,
            Int32(ACL_FIRST_ENTRY.rawValue),
            &entry
        ) == 1
    }
}
