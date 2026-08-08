import Foundation
import XCTest
@testable import MacICNS

final class IconApplyRequestTests: XCTestCase {
    func testRejectsNonApplicationTarget() throws {
        XCTAssertThrowsError(
            try IconApplyRequest(
                applicationURL: URL(filePath: "/tmp/file"),
                iconURL: URL(filePath: "/tmp/icon.icns")
            )
        )
    }

    func testRejectsNonICNSIcon() throws {
        XCTAssertThrowsError(
            try IconApplyRequest(
                applicationURL: URL(filePath: "/tmp/Test.app"),
                iconURL: URL(filePath: "/tmp/icon.png")
            )
        )
    }
}
