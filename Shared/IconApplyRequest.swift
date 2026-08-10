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
    let iconData: Data

    convenience init(applicationURL: URL, iconURL: URL) throws {
        let validatedApplicationURL = try Self.validateApplicationURL(applicationURL)
        let validatedIconURL = try Self.validateIconURL(iconURL)
        let iconData: Data
        do {
            iconData = try IconDataReader.data(at: validatedIconURL)
        } catch {
            throw ValidationError.iconMustBeAnExistingICNSFile
        }
        try Self.validateIconData(iconData)
        self.init(
            applicationURL: validatedApplicationURL,
            iconURL: validatedIconURL,
            iconData: iconData
        )
    }

    required convenience init?(coder: NSCoder) {
        guard let applicationURL = coder.decodeObject(of: NSURL.self, forKey: "applicationURL") as URL?,
              let iconURL = coder.decodeObject(of: NSURL.self, forKey: "iconURL") as URL?,
              let iconData = coder.decodeObject(of: NSData.self, forKey: "iconData") as Data?
        else {
            return nil
        }

        do {
            let validatedApplicationURL = try Self.validateApplicationReference(applicationURL)
            let validatedIconURL = try Self.validateIconReference(iconURL)
            try Self.validateIconData(iconData)
            self.init(
                applicationURL: validatedApplicationURL,
                iconURL: validatedIconURL,
                iconData: iconData
            )
        } catch {
            return nil
        }
    }

    func encode(with coder: NSCoder) {
        coder.encode(applicationURL as NSURL, forKey: "applicationURL")
        coder.encode(iconURL as NSURL, forKey: "iconURL")
        coder.encode(iconData as NSData, forKey: "iconData")
    }

    func revalidated() throws -> IconApplyRequest {
        let validatedApplicationURL = try Self.validateApplicationReference(applicationURL)
        let validatedIconURL = try Self.validateIconReference(iconURL)
        try Self.validateIconData(iconData)
        return IconApplyRequest(
            applicationURL: validatedApplicationURL,
            iconURL: validatedIconURL,
            iconData: iconData
        )
    }

    private init(applicationURL: URL, iconURL: URL, iconData: Data) {
        self.applicationURL = applicationURL
        self.iconURL = iconURL
        self.iconData = iconData
        super.init()
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

    private static func validateApplicationReference(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ValidationError.applicationMustBeAnExistingBundle
        }
        let standardizedURL = url.standardizedFileURL
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
              isExistingRegularFile(standardizedURL)
        else {
            throw ValidationError.iconMustBeAnExistingICNSFile
        }
        return standardizedURL
    }

    private static func validateIconReference(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ValidationError.iconMustBeAnExistingICNSFile
        }
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.pathExtension.caseInsensitiveCompare("icns") == .orderedSame else {
            throw ValidationError.iconMustBeAnExistingICNSFile
        }
        return standardizedURL
    }

    private static func validateIconData(_ data: Data) throws {
        guard data.count <= Int(IconDataReader.maximumIconByteCount),
              NSImage(data: data) != nil
        else {
            throw ValidationError.iconMustBeAnExistingICNSFile
        }
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
