import AppKit
import Foundation

@MainActor
struct ApplicationIconProvider {
    private let imageLoader: (URL) -> NSImage?
    private let workspaceIconLoader: (String) -> NSImage

    init(
        imageLoader: @escaping (URL) -> NSImage? = { NSImage(contentsOf: $0) },
        workspaceIconLoader: @escaping (String) -> NSImage = { _ in
            NSWorkspace.shared.icon(for: .applicationBundle)
        }
    ) {
        self.imageLoader = imageLoader
        self.workspaceIconLoader = workspaceIconLoader
    }

    func originalIcon(for applicationURL: URL) -> NSImage {
        if let iconURL = originalIconURL(for: applicationURL),
           let icon = imageLoader(iconURL)
        {
            return icon
        }
        return workspaceIconLoader(applicationURL.path)
    }

    func customIcon(at iconURL: URL) -> NSImage {
        imageLoader(iconURL) ?? workspaceIconLoader(iconURL.path)
    }

    private func originalIconURL(for applicationURL: URL) -> URL? {
        guard let bundle = Bundle(url: applicationURL),
              let resourcesURL = bundle.resourceURL,
              var iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !iconFile.isEmpty
        else {
            return nil
        }
        if URL(filePath: iconFile).pathExtension.isEmpty {
            iconFile += ".icns"
        }
        return resourcesURL.appending(path: iconFile).absoluteURL.standardizedFileURL
    }
}
