import Carbon.HIToolbox
import XCTest
@testable import PocketIMGShot

final class ConfigurationTests: XCTestCase {
    @MainActor
    func testMenuBarIconUsesAReusableTemplateAsset() throws {
        let image = try XCTUnwrap(NSImage(named: "MenuBarIcon"))

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, CGSize(width: 18, height: 18))
    }

    func testPinnedImageAcceptsTheFirstClickFromAnotherApplication() {
        let view = PinnedImageView(frame: .zero)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    @MainActor
    func testCapturePreparationViewTakesImmediateInputAndCancelsWithEscape() throws {
        var cancelled = false
        let view = CapturePreparationView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)) {
            cancelled = true
        }

        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        ))
        view.keyDown(with: escape)

        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testCaptureOverlayInitializesPixelInspectorWithoutClaimingCursorFromInactiveWindow() {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 200, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = CaptureOverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        view.initializeHoverPoint(atScreenPoint: CGPoint(x: 340, y: 440))

        XCTAssertEqual(view.hoverPoint, CGPoint(x: 240, y: 360))
        XCTAssertFalse(view.synchronizeCursor(atScreenPoint: CGPoint(x: 340, y: 440)))
    }

    func testAutomaticUpdateFeedUsesSignedHTTPSAppcast() throws {
        let info = Bundle.main.infoDictionary

        XCTAssertEqual(
            info?["SUFeedURL"] as? String,
            "https://github.com/gmch1/pocket-img/releases/download/macos-appcast/appcast.xml"
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

    func testDefaultVideoHotKeyIsF2() {
        XCTAssertEqual(HotKey.videoDefault.keyCode, UInt32(kVK_F2))
        XCTAssertEqual(HotKey.videoDefault.displayName, "F2")
        XCTAssertEqual(HotKey.videoDefault.modifiers, 0)
    }

    func testGlobalHotKeysOnlyHandleTheirOwnCarbonIdentifier() {
        let captureHotKey = GlobalHotKey(identifier: 1)
        let escapeHotKey = GlobalHotKey(identifier: 2)
        let captureIdentifier = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)
        let escapeIdentifier = EventHotKeyID(signature: GlobalHotKey.signature, id: 2)
        let foreignIdentifier = EventHotKeyID(signature: 0, id: 1)

        XCTAssertTrue(captureHotKey.matches(captureIdentifier))
        XCTAssertFalse(captureHotKey.matches(escapeIdentifier))
        XCTAssertFalse(captureHotKey.matches(foreignIdentifier))
        XCTAssertTrue(escapeHotKey.matches(escapeIdentifier))
        XCTAssertFalse(escapeHotKey.matches(captureIdentifier))
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
        settings.videoHotKey = HotKey(keyCode: 4, modifiers: 512, keyLabel: "H")
        settings.persistLanguage(.english)
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
        XCTAssertEqual(restored.videoHotKey, settings.videoHotKey)
        XCTAssertEqual(restored.language, .english)
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
        XCTAssertEqual(migrated.videoHotKey, .videoDefault)
        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual(storedObject["schemaVersion"] as? Int, 6)
        XCTAssertEqual(storedObject["hotKeyLabel"] as? String, "F1")
        XCTAssertEqual(storedObject["gifHotKeyLabel"] as? String, "F2")
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
        XCTAssertEqual(customized.annotationStyle.arrowLineWidth, 4)
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
        XCTAssertEqual(restored.videoHotKey, .videoDefault)
    }

    @MainActor
    func testVideoHotKeyPersistsWithoutOverwritingScreenshotHotKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketIMGShotVideoHotKeyTests-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshotHotKey = HotKey(keyCode: 3, modifiers: 256, keyLabel: "F")
        let videoHotKey = HotKey(keyCode: 4, modifiers: 512, keyLabel: "H")
        let settings = AppSettings(settingsURL: settingsURL)

        settings.persistHotKey(screenshotHotKey)
        settings.persistVideoHotKey(videoHotKey)

        let restored = AppSettings(settingsURL: settingsURL)
        XCTAssertEqual(restored.hotKey, screenshotHotKey)
        XCTAssertEqual(restored.videoHotKey, videoHotKey)
    }

    @MainActor
    func testAddingVideoShortcutDoesNotRewriteAnExistingScreenshotF2() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketIMGShotVideoMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousSchemaJSON = """
        {
          "schemaVersion": 5,
          "serverAddress": "https://img.example.com",
          "token": "token",
          "hotKeyCode": \(UInt32(kVK_F2)),
          "hotKeyModifiers": 0,
          "hotKeyLabel": "F2"
        }
        """
        try XCTUnwrap(previousSchemaJSON.data(using: .utf8)).write(to: settingsURL)

        let migrated = AppSettings(settingsURL: settingsURL)

        XCTAssertEqual(migrated.hotKey, .videoDefault)
        XCTAssertEqual(migrated.videoHotKey, .videoDefault)
        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual(storedObject["schemaVersion"] as? Int, 6)
        XCTAssertEqual(storedObject["hotKeyLabel"] as? String, "F2")
        XCTAssertEqual(storedObject["gifHotKeyLabel"] as? String, "F2")
    }

    @MainActor
    func testMigratesSeparateLineWidthsToOneSharedValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketIMGShotSharedLineWidthTests-\(UUID().uuidString)")
        let settingsURL = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "schemaVersion": 3,
          "serverAddress": "https://img.example.com",
          "token": "token",
          "hotKeyCode": 122,
          "hotKeyModifiers": 0,
          "hotKeyLabel": "F1",
          "annotationStyle": {
            "rectangleLineWidth": 2,
            "arrowLineWidth": 6,
            "textFontSize": 24,
            "color": "red"
          }
        }
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: settingsURL)

        let migrated = AppSettings(settingsURL: settingsURL)

        XCTAssertEqual(migrated.annotationStyle.rectangleLineWidth, 6)
        XCTAssertEqual(migrated.annotationStyle.arrowLineWidth, 6)
        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual(storedObject["schemaVersion"] as? Int, 6)
    }

    @MainActor
    func testExplicitLanguageResourcesAndShortcutLabels() {
        XCTAssertEqual(L10n.text("settings.save", language: .simplifiedChinese), "保存")
        XCTAssertEqual(L10n.text("settings.save", language: .english), "Save")
        XCTAssertEqual(
            L10n.text("settings.server_address.help", language: .simplifiedChinese),
            "局域网地址支持 HTTP。"
        )
        XCTAssertEqual(
            L10n.text("settings.connection_credential", language: .simplifiedChinese),
            "连接凭证（Token）"
        )
        XCTAssertEqual(
            L10n.text("settings.connection_credential", language: .english),
            "Connection Credential (Token)"
        )
        XCTAssertEqual(
            L10n.text("settings.hotkey.help", language: .english),
            "Click and press a new shortcut. Some Macs also require Fn."
        )
        XCTAssertEqual(
            L10n.text("settings.screenshot_hotkey", language: .simplifiedChinese),
            "截图快捷键"
        )
        XCTAssertEqual(
            L10n.text("settings.video_hotkey", language: .english),
            "Record Video Shortcut"
        )
        let space = HotKey(keyCode: UInt32(kVK_Space), modifiers: 0, keyLabel: "Space")
        XCTAssertEqual(space.localizedDisplayName(language: .simplifiedChinese), "空格")
        XCTAssertEqual(space.localizedDisplayName(language: .english), "Space")
    }
}
