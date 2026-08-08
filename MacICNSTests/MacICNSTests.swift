import XCTest
@testable import MacICNS

final class MacICNSTests: XCTestCase {
    func testApplicationBootstraps() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.guigx.macicns")
    }

    func testFileSelectionValidatorAcceptsOnlyExpectedExtensions() {
        XCTAssertTrue(FileSelectionValidator.isApplication(URL(filePath: "/Applications/Example.app")))
        XCTAssertFalse(FileSelectionValidator.isApplication(URL(filePath: "/Applications/Example.icns")))
        XCTAssertTrue(FileSelectionValidator.isIcon(URL(filePath: "/tmp/Icon.icns")))
        XCTAssertFalse(FileSelectionValidator.isIcon(URL(filePath: "/tmp/Icon.png")))
    }
}
