import AppKit
import Foundation

struct ApplicationLocator: ApplicationLocating {
    func resolve(_ bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
