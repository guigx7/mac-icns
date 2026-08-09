import AppKit
import Foundation

@objc(IconApplyRequest)
final class IconApplyRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case applicationMustBeAnExistingBundle
        case iconMustBeAnExistingICNSFile
        case symbolicLinksAreNotAllowed
    }

    static var supportsSecureCoding: Bool { true }

    let applicationURL: URL
    let iconURL: URL

    init(applicationURL: URL, iconURL: URL) throws {
        self.applicationURL = try Self.validateApplicationURL(applicationURL)
        self.iconURL = try Self.validateIconURL(iconURL)
        super.init()
    }

    required convenience init?(coder: NSCoder) {
        guard let applicationURL = coder.decodeObject(of: NSURL.self, forKey: "applicationURL") as URL?,
              let iconURL = coder.decodeObject(of: NSURL.self, forKey: "iconURL") as URL?
        else {
            return nil
        }

        do {
            try self.init(applicationURL: applicationURL, iconURL: iconURL)
        } catch {
            return nil
        }
    }

    func encode(with coder: NSCoder) {
        coder.encode(applicationURL as NSURL, forKey: "applicationURL")
        coder.encode(iconURL as NSURL, forKey: "iconURL")
    }

    fileprivate static func validateApplicationURL(_ url: URL) throws -> URL {
        let standardizedURL = try validatedStandardFileURL(url)
        guard standardizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              isExistingDirectory(standardizedURL)
        else {
            throw ValidationError.applicationMustBeAnExistingBundle
        }
        return standardizedURL
    }

    private static func validateIconURL(_ url: URL) throws -> URL {
        let standardizedURL = try validatedStandardFileURL(url)
        guard standardizedURL.pathExtension.caseInsensitiveCompare("icns") == .orderedSame,
              isExistingRegularFile(standardizedURL),
              NSImage(contentsOf: standardizedURL) != nil
        else {
            throw ValidationError.iconMustBeAnExistingICNSFile
        }
        return standardizedURL
    }

    private static func validatedStandardFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ValidationError.symbolicLinksAreNotAllowed
        }

        let standardizedURL = url.standardizedFileURL
        guard !containsSymbolicLink(in: standardizedURL) else {
            throw ValidationError.symbolicLinksAreNotAllowed
        }
        return standardizedURL
    }

    private static func containsSymbolicLink(in url: URL) -> Bool {
        var componentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            componentURL.appendPathComponent(component)
            if (try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isExistingRegularFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        else {
            return false
        }
        return values.isRegularFile == true
    }
}

@objc(IconResetRequest)
final class IconResetRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let applicationURL: URL

    init(applicationURL: URL) throws {
        self.applicationURL = try IconApplyRequest.validateApplicationURL(applicationURL)
        super.init()
    }

    required convenience init?(coder: NSCoder) {
        guard let applicationURL = coder.decodeObject(of: NSURL.self, forKey: "applicationURL") as URL? else {
            return nil
        }
        do {
            try self.init(applicationURL: applicationURL)
        } catch {
            return nil
        }
    }

    func encode(with coder: NSCoder) {
        coder.encode(applicationURL as NSURL, forKey: "applicationURL")
    }
}
