import AppKit
import XCTest
@testable import MacICNS

@MainActor
final class ApplicationIconProviderTests: XCTestCase {
    func testOriginalIconLoadsBundleIconResourceBeforeWorkspaceFallback() throws {
        let fixture = try ApplicationBundleFixture(iconFile: "OriginalIcon")
        defer { fixture.remove() }
        let expected = NSImage(size: NSSize(width: 32, height: 32))
        var loadedURLs: [URL] = []
        var fallbackPaths: [String] = []
        let provider = ApplicationIconProvider(
            imageLoader: { url in
                loadedURLs.append(url)
                return expected
            },
            workspaceIconLoader: { path in
                fallbackPaths.append(path)
                return NSImage()
            }
        )

        let icon = provider.originalIcon(for: fixture.applicationURL)

        XCTAssertTrue(icon === expected)
        XCTAssertEqual(loadedURLs, [fixture.resourcesURL.appending(path: "OriginalIcon.icns")])
        XCTAssertTrue(fallbackPaths.isEmpty)
    }

    func testOriginalIconFallsBackToWorkspaceWhenBundleHasNoLoadableIcon() throws {
        let fixture = try ApplicationBundleFixture(iconFile: nil)
        defer { fixture.remove() }
        let expected = NSImage(size: NSSize(width: 32, height: 32))
        var fallbackPaths: [String] = []
        let provider = ApplicationIconProvider(
            imageLoader: { _ in nil },
            workspaceIconLoader: { path in
                fallbackPaths.append(path)
                return expected
            }
        )

        let icon = provider.originalIcon(for: fixture.applicationURL)

        XCTAssertTrue(icon === expected)
        XCTAssertEqual(fallbackPaths, [fixture.applicationURL.path])
    }

    func testCustomIconLoadsSelectedICNSFile() {
        let expected = NSImage(size: NSSize(width: 32, height: 32))
        let iconURL = URL(filePath: "/tmp/Custom.icns")
        var loadedURLs: [URL] = []
        let provider = ApplicationIconProvider(
            imageLoader: { url in
                loadedURLs.append(url)
                return expected
            },
            workspaceIconLoader: { _ in NSImage() }
        )

        let icon = provider.customIcon(at: iconURL)

        XCTAssertTrue(icon === expected)
        XCTAssertEqual(loadedURLs, [iconURL])
    }
}

private struct ApplicationBundleFixture {
    let directory: URL
    let applicationURL: URL
    let resourcesURL: URL

    init(iconFile: String?) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        applicationURL = directory.appending(path: "Example.app", directoryHint: .isDirectory)
        let contentsURL = applicationURL.appending(path: "Contents", directoryHint: .isDirectory)
        resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.example.icon-provider"]
        if let iconFile {
            info["CFBundleIconFile"] = iconFile
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appending(path: "Info.plist"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
