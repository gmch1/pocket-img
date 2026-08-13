import Carbon.HIToolbox
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

    func testDefaultHotKeyIsF1() {
        XCTAssertEqual(HotKey.default.keyCode, UInt32(kVK_F1))
        XCTAssertEqual(HotKey.default.displayName, "F1")
        XCTAssertEqual(HotKey.default.modifiers, 0)
    }

    @MainActor
    func testSettingsPersistAcrossAppInstancesWithoutKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketIMGShotTests-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let settings = AppSettings(settingsURL: settingsURL)
        settings.serverAddress = "https://img.example.com/"
        settings.token = "test-token"
        settings.hotKey = HotKey(keyCode: 3, modifiers: 256, keyLabel: "F")
        try settings.save()

        let restored = AppSettings(settingsURL: settingsURL)
        XCTAssertEqual(restored.serverAddress, "https://img.example.com")
        XCTAssertEqual(restored.token, "test-token")
        XCTAssertEqual(restored.hotKey, settings.hotKey)
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }
}
