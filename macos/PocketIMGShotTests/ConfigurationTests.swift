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

    @MainActor
    func testSettingsPersistAcrossAppInstancesWithoutKeychain() throws {
        let suiteName = "PocketIMGShotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.serverAddress = "https://img.example.com/"
        settings.token = "test-token"
        settings.hotKey = HotKey(keyCode: 3, modifiers: 256, keyLabel: "F")
        try settings.save()

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.serverAddress, "https://img.example.com")
        XCTAssertEqual(restored.token, "test-token")
        XCTAssertEqual(restored.hotKey, settings.hotKey)
    }
}
