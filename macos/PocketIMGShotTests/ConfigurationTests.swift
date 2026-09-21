import Carbon.HIToolbox
import XCTest
@testable import PocketIMGShot

final class ConfigurationTests: XCTestCase {
    @MainActor
    func testCaptureInputCanReadPhysicalButtonsWithoutInstallingATap() {
        XCTAssertEqual(CaptureInputGuard.pressedButtons >> 32, 0)
    }

    func testCaptureInputSuppressesCompleteClicksForEachMouseButton() {
        let gestures: [(CGEventType, CGEventType, CGEventType, Int64)] = [
            (.leftMouseDown, .leftMouseDragged, .leftMouseUp, 0),
            (.rightMouseDown, .rightMouseDragged, .rightMouseUp, 1),
            (.otherMouseDown, .otherMouseDragged, .otherMouseUp, 2),
            (.otherMouseDown, .otherMouseDragged, .otherMouseUp, 4),
        ]
        for (down, drag, up, button) in gestures {
            var state = CaptureMouseInputState(pressedButtons: 0)
            XCTAssertTrue(state.shouldSuppress(down, button: button))
            XCTAssertTrue(state.shouldSuppress(drag, button: button))
            XCTAssertTrue(state.shouldSuppress(up, button: button))
            XCTAssertEqual(state.swallowedButtons, 0)
        }
    }

    func testCaptureInputPreservesHoverMovementAndEscape() {
        var state = CaptureMouseInputState(pressedButtons: 0)
        XCTAssertFalse(state.shouldSuppress(.mouseMoved))
        XCTAssertFalse(state.shouldSuppress(.keyDown))
        XCTAssertFalse(state.shouldSuppress(.keyUp))
        XCTAssertTrue(state.shouldSuppress(.scrollWheel))
        state.finish()
        XCTAssertFalse(state.shouldSuppress(.scrollWheel))
        XCTAssertFalse(state.shouldSuppress(.leftMouseDown))
    }

    func testCaptureInputLetsAnExistingDragFinishWithoutAStuckButton() {
        var state = CaptureMouseInputState(pressedButtons: 1)
        XCTAssertFalse(state.shouldSuppress(.leftMouseDragged))
        XCTAssertFalse(state.shouldSuppress(.leftMouseUp))
        // A subsequent click during preparation is intercepted normally.
        XCTAssertTrue(state.shouldSuppress(.leftMouseDown))
        XCTAssertTrue(state.shouldSuppress(.leftMouseUp))
    }

    func testCaptureCancellationOnlyDrainsAlreadySuppressedGestures() {
        var state = CaptureMouseInputState(pressedButtons: 0)
        XCTAssertTrue(state.shouldSuppress(.leftMouseDown))
        state.finish()
        // New input is immediately usable while the original button is held.
        XCTAssertFalse(state.shouldSuppress(.rightMouseDown, button: 1))
        XCTAssertFalse(state.shouldSuppress(.rightMouseUp, button: 1))
        XCTAssertFalse(state.shouldSuppress(.scrollWheel))
        XCTAssertTrue(state.shouldSuppress(.leftMouseDragged))
        XCTAssertTrue(state.shouldSuppress(.leftMouseUp))
        XCTAssertEqual(state.swallowedButtons, 0)
        XCTAssertFalse(state.shouldSuppress(.leftMouseDown))
        XCTAssertFalse(state.shouldSuppress(.leftMouseUp))
    }

    func testCaptureInputDrainCanRecoverFromAMissedDeviceRelease() {
        var state = CaptureMouseInputState(pressedButtons: 0)
        XCTAssertTrue(state.shouldSuppress(.leftMouseDown))
        XCTAssertTrue(state.shouldSuppress(.rightMouseDown, button: 1))
        state.finish()
        state.discardReleasedButtons(pressedButtons: 2)
        XCTAssertEqual(state.swallowedButtons, 2)
        state.discardReleasedButtons(pressedButtons: 0)
        XCTAssertEqual(state.swallowedButtons, 0)
    }

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
    func testPixelInspectorExitsOnlyAfterCopyingHoveredHexColor() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 200, width: 2, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = CaptureOverlayView(frame: CGRect(x: 0, y: 0, width: 2, height: 1))
        window.contentView = view
        let delegate = ColorCopyExitObserver()
        view.delegate = delegate
        let copy = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_C)
        ))
        // Copy is unavailable before a screenshot and hover position exist.
        XCTAssertFalse(view.performKeyEquivalent(with: copy))
        XCTAssertEqual(delegate.exitCount, 0)
        XCTAssertTrue(view.isSelecting)

        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        view.screenshot = try XCTUnwrap(context.makeImage())

        // Retina coordinates must select the same pixel as the magnifier.
        view.initializeHoverPoint(atScreenPoint: CGPoint(x: 100.25, y: 200.75))
        // A failed copy reported by the coordinator must keep the session open.
        view.onCopySampledColor = { false }
        XCTAssertFalse(view.performKeyEquivalent(with: copy))
        XCTAssertEqual(delegate.exitCount, 0)
        XCTAssertTrue(view.isSelecting)
        view.onCopySampledColor = nil

        XCTAssertTrue(view.performKeyEquivalent(with: copy))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "#FF0000")
        XCTAssertEqual(delegate.colorAtExit, "#FF0000")
        XCTAssertEqual(delegate.exitCount, 1)
        XCTAssertFalse(view.isSelecting)
    }

    @MainActor
    func testColorCopyUsesPointerWindowInsteadOfKeyWindow() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let windows = [0, 1].map { index in
            let window = CaptureWindow(
                contentRect: CGRect(x: 100 + index * 100, y: 100, width: 80, height: 80),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = CaptureOverlayView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
            window.orderFrontRegardless()
            return window
        }
        defer { windows.forEach { $0.close() } }
        for (index, window) in windows.enumerated() {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 640,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(srgbRed: index == 0 ? 1 : 0,
                                         green: 0, blue: index == 1 ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            (window.contentView as? CaptureOverlayView)?.screenshot = try XCTUnwrap(context.makeImage())
        }
        windows[0].makeKey()
        // Start with a stale sample on the original screen.
        (windows[0].contentView as? CaptureOverlayView)?.initializeHoverPoint(
            atScreenPoint: CGPoint(x: 120, y: 120)
        )
        XCTAssertTrue(CaptureCoordinator.copySampledColor(
            at: CGPoint(x: 220, y: 120), in: windows, to: pasteboard
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "#0000FF")
        // The key window must exit the session after the other screen's color
        // has reached the clipboard through the coordinator callback.
        let receiver = try XCTUnwrap(windows[0].contentView as? CaptureOverlayView)
        let delegate = ColorCopyExitObserver()
        receiver.delegate = delegate
        receiver.onCopySampledColor = {
            CaptureCoordinator.copySampledColor(
                at: CGPoint(x: 220, y: 120), in: windows, to: .general
            )
        }
        let copy = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: windows[0].windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_C)
        ))
        XCTAssertTrue(receiver.performKeyEquivalent(with: copy))
        XCTAssertEqual(delegate.colorAtExit, "#0000FF")
        XCTAssertEqual(delegate.exitCount, 1)
        XCTAssertFalse(receiver.isSelecting)
        receiver.onCopySampledColor = nil

        XCTAssertFalse(CaptureCoordinator.copySampledColor(
            at: CGPoint(x: 400, y: 120), in: windows, to: pasteboard
        ))
        windows[1].orderOut(nil)
        XCTAssertFalse(CaptureCoordinator.copySampledColor(
            at: CGPoint(x: 220, y: 120), in: windows, to: pasteboard
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "#0000FF")
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

@MainActor
private final class ColorCopyExitObserver: CaptureOverlayViewDelegate {
    private(set) var exitCount = 0
    private(set) var colorAtExit: String?

    func captureOverlayDidStartSelection(_ overlay: CaptureOverlayView) {}

    func captureOverlayDidCancel(_ overlay: CaptureOverlayView) {
        exitCount += 1
        colorAtExit = NSPasteboard.general.string(forType: .string)
    }

    func captureOverlay(_ overlay: CaptureOverlayView, didFinish payload: UploadPayload, action: CaptureAction) {
        XCTFail("Copying a color must not export a screenshot")
    }

    func captureOverlay(_ overlay: CaptureOverlayView, didFailWith error: Error) {
        XCTFail("Unexpected color copy error: \(error)")
    }
}
