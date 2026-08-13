import Carbon.HIToolbox
import XCTest
@testable import PocketIMGShot

final class ConfigurationTests: XCTestCase {
    func testPinnedImageAcceptsTheFirstClickFromAnotherApplication() {
        let view = PinnedImageView(frame: .zero)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testAutomaticUpdateFeedUsesSignedHTTPSAppcast() throws {
        let info = Bundle.main.infoDictionary

        XCTAssertEqual(
            info?["SUFeedURL"] as? String,
            "https://github.com/gmch1/pocket-img/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(info?["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info?["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info?["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(info?["SUPublicEDKey"] as? String).count, 44)
    }

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
    func testUploadIsAvailableOnlyWithACompleteBackendConfiguration() {
        let settings = AppSettings(
            settingsURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("PocketIMGShotUploadState-\(UUID().uuidString).json")
        )

        XCTAssertFalse(settings.hasUploadConfiguration)

        settings.serverAddress = "https://img.example.com"
        XCTAssertFalse(settings.hasUploadConfiguration)

        settings.token = "test-token"
        XCTAssertTrue(settings.hasUploadConfiguration)

        settings.serverAddress = "not-a-url"
        XCTAssertFalse(settings.hasUploadConfiguration)
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
        settings.updateAnnotationStyle(AnnotationStylePreferences(
            rectangleLineWidth: 5.5,
            arrowLineWidth: 7,
            textFontSize: 28,
            color: .blue
        ))
        try settings.save()

        let restored = AppSettings(settingsURL: settingsURL)
        XCTAssertEqual(restored.serverAddress, "https://img.example.com")
        XCTAssertEqual(restored.token, "test-token")
        XCTAssertEqual(restored.hotKey, settings.hotKey)
        XCTAssertEqual(restored.annotationStyle, settings.annotationStyle)
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    @MainActor
    func testMigratesLegacyDefaultF2ToF1WithoutLosingConnectionSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketIMGShotLegacyTests-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "serverAddress": "https://img.example.com",
          "token": "legacy-token",
          "hotKeyCode": \(UInt32(kVK_F2)),
          "hotKeyModifiers": 0,
          "hotKeyLabel": "F2"
        }
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: settingsURL)

        let migrated = AppSettings(settingsURL: settingsURL)

        XCTAssertEqual(migrated.serverAddress, "https://img.example.com")
        XCTAssertEqual(migrated.token, "legacy-token")
        XCTAssertEqual(migrated.hotKey, .default)
        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual(storedObject["schemaVersion"] as? Int, 3)
        XCTAssertEqual(storedObject["hotKeyLabel"] as? String, "F1")
    }

    @MainActor
    func testMigratesOnlyUntouchedLegacyDefaultLineWidths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketIMGShotStyleMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let customSettingsURL = directory.appendingPathComponent("custom-settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "serverAddress": "https://img.example.com",
          "token": "style-token",
          "hotKeyCode": 122,
          "hotKeyModifiers": 0,
          "hotKeyLabel": "F1",
          "annotationStyle": {
            "rectangleLineWidth": 3,
            "arrowLineWidth": 3,
            "textFontSize": 28,
            "color": "blue"
          }
        }
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: settingsURL)

        let migrated = AppSettings(settingsURL: settingsURL)

        XCTAssertEqual(migrated.serverAddress, "https://img.example.com")
        XCTAssertEqual(migrated.token, "style-token")
        XCTAssertEqual(migrated.annotationStyle.rectangleLineWidth, 2)
        XCTAssertEqual(migrated.annotationStyle.arrowLineWidth, 2)
        XCTAssertEqual(migrated.annotationStyle.textFontSize, 28)
        XCTAssertEqual(migrated.annotationStyle.resolvedColor, .blue)

        let customizedJSON = legacyJSON
            .replacingOccurrences(of: "\"rectangleLineWidth\": 3", with: "\"rectangleLineWidth\": 4")
        try XCTUnwrap(customizedJSON.data(using: .utf8)).write(to: customSettingsURL)
        let customized = AppSettings(settingsURL: customSettingsURL)
        XCTAssertEqual(customized.annotationStyle.rectangleLineWidth, 4)
        XCTAssertEqual(customized.annotationStyle.arrowLineWidth, 3)
    }

    @MainActor
    func testExplicitF2InCurrentSchemaIsNotMigrated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketIMGShotCurrentTests-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = AppSettings(settingsURL: settingsURL)
        settings.serverAddress = "https://img.example.com"
        settings.token = "token"
        settings.persistHotKey(HotKey(
            keyCode: UInt32(kVK_F2),
            modifiers: 0,
            keyLabel: "F2"
        ))

        let restored = AppSettings(settingsURL: settingsURL)
        XCTAssertEqual(restored.hotKey.displayName, "F2")
    }
}
