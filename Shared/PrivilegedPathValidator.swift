import Darwin
import Foundation

enum PrivilegedPathValidator {
    enum ValidationError: Error, Equatable, Sendable {
        case targetIsMutableByUnprivilegedUser
        case unsafePath
    }

    /// A pathname can only be passed to NSWorkspace after each component is protected
    /// from replacement by any unprivileged user. This makes the later pathname operation
    /// safe from symlink or rename races despite NSWorkspace accepting a pathname, not a
    /// file descriptor.
    static func validate(applicationURL: URL) throws {
        var path = "/"

        for component in applicationURL.standardizedFileURL.pathComponents.dropFirst() {
            path = (path as NSString).appendingPathComponent(component)
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                throw ValidationError.unsafePath
            }
            guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
                throw ValidationError.unsafePath
            }
            guard metadata.st_uid == 0,
                  (metadata.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  !hasExtendedACL(at: path)
            else {
                throw ValidationError.targetIsMutableByUnprivilegedUser
            }
        }
    }

    /// Conservatively reject a path that carries an extended ACL. ACLs can grant write
    /// access independently of the POSIX mode bits, so accepting one would reintroduce
    /// a replacement race before the pathname-only NSWorkspace call.
    private static func hasExtendedACL(at path: String) -> Bool {
        errno = 0
        guard let accessControlList = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
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
