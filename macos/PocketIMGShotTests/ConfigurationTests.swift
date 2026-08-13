import XCTest
@testable import PocketIMGShot

final class ConfigurationTests: XCTestCase {
    func testNormalizesServerAddress() throws {
        XCTAssertEqual(
            try ServiceConfiguration.normalizeBaseURL(" https://img.example.com/ ").absoluteString,
            "https://img.example.com"
        )
        XCTAssertEqual(
            try ServiceConfiguration.normalizeBaseURL("http://192.168.1.10:8080").absoluteString,
            "http://192.168.1.10:8080"
        )
    }

    func testRejectsServerPathAndCredentials() {
        XCTAssertThrowsError(try ServiceConfiguration.normalizeBaseURL("https://img.example.com/gallery"))
        XCTAssertThrowsError(try ServiceConfiguration.normalizeBaseURL("https://user:pass@img.example.com"))
    }

    func testDefaultHotKeyIsF2() {
        XCTAssertEqual(HotKey.default.displayName, "F2")
        XCTAssertEqual(HotKey.default.modifiers, 0)
    }
}
