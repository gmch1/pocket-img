import Combine
import Carbon.HIToolbox
import Foundation

private struct StoredSettings: Codable {
    let schemaVersion: Int?
    let serverAddress: String
    let token: String
    let hotKeyCode: UInt32
    let hotKeyModifiers: UInt
    let hotKeyLabel: String
    let videoHotKeyCode: UInt32?
    let videoHotKeyModifiers: UInt?
    let videoHotKeyLabel: String?
    let annotationStyle: AnnotationStylePreferences?
    let language: AppLanguage?

    // Keep the original JSON keys so upgrading from the GIF experiment does
    // not reset the user's F2 shortcut.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case serverAddress
        case token
        case hotKeyCode
        case hotKeyModifiers
        case hotKeyLabel
        case videoHotKeyCode = "gifHotKeyCode"
        case videoHotKeyModifiers = "gifHotKeyModifiers"
        case videoHotKeyLabel = "gifHotKeyLabel"
        case annotationStyle
        case language
    }
}

private struct SettingsStore {
    let fileURL: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("PocketIMGShot", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    func load() throws -> StoredSettings? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(StoredSettings.self, from: Data(contentsOf: fileURL))
    }

    func save(_ value: StoredSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try JSONEncoder().encode(value).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

struct ServiceConfiguration: Equatable, Sendable {
    let baseURL: URL
    let token: String

    static func normalizeBaseURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw SettingsError.invalidServerAddress
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty else {
            throw SettingsError.serverAddressHasPath
        }
        components.path = ""
        guard let url = components.url else {
            throw SettingsError.invalidServerAddress
        }
        return url
    }
}

enum SettingsError: LocalizedError, AppLocalizedError {
    case invalidServerAddress
    case serverAddressHasPath
    case missingToken

    var errorDescription: String? {
        localizedMessage(language: .system)
    }

    func localizedMessage(language: AppLanguage) -> String {
        switch self {
        case .invalidServerAddress:
            return L10n.text("error.invalid_server_address", language: language)
        case .serverAddressHasPath:
            return L10n.text("error.server_address_has_path", language: language)
        case .missingToken:
            return L10n.text("error.missing_token", language: language)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private static let currentSchemaVersion = 6

    @Published var serverAddress: String
    @Published var token: String
    @Published var hotKey: HotKey
    @Published var videoHotKey: HotKey
    @Published var language: AppLanguage
    @Published var hotKeyRegistrationError = ""
    private(set) var annotationStyle: AnnotationStylePreferences

    private let store: SettingsStore
    private var annotationStyleSaveTask: Task<Void, Never>?

    init(settingsURL: URL? = nil) {
        store = SettingsStore(fileURL: settingsURL ?? SettingsStore.defaultURL)

        if let stored = try? store.load() {
            let storedHotKey = HotKey(
                keyCode: stored.hotKeyCode,
                modifiers: stored.hotKeyModifiers,
                keyLabel: stored.hotKeyLabel
            )
            let shouldMigrateLegacyF2 = stored.schemaVersion == nil
                && storedHotKey.keyCode == UInt32(kVK_F2)
                && storedHotKey.modifiers == 0
                && storedHotKey.keyLabel.uppercased() == "F2"
            let resolvedHotKey = shouldMigrateLegacyF2 ? HotKey.default : storedHotKey
            let resolvedVideoHotKey: HotKey
            if let keyCode = stored.videoHotKeyCode,
               let modifiers = stored.videoHotKeyModifiers,
               let keyLabel = stored.videoHotKeyLabel,
               !keyLabel.isEmpty {
                resolvedVideoHotKey = HotKey(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    keyLabel: keyLabel
                )
            } else {
                resolvedVideoHotKey = .videoDefault
            }
            let storedAnnotationStyle = stored.annotationStyle
            let shouldMigrateDefaultLineWidths = stored.schemaVersion == 2
                && storedAnnotationStyle?.rectangleLineWidth == 3
                && storedAnnotationStyle?.arrowLineWidth == 3
            let resolvedAnnotationStyle: AnnotationStylePreferences
            if shouldMigrateDefaultLineWidths, let storedAnnotationStyle {
                resolvedAnnotationStyle = AnnotationStylePreferences(
                    rectangleLineWidth: AnnotationStylePreferences.default.rectangleLineWidth,
                    arrowLineWidth: AnnotationStylePreferences.default.arrowLineWidth,
                    textFontSize: storedAnnotationStyle.textFontSize,
                    color: storedAnnotationStyle.resolvedColor
                ).normalized
            } else {
                resolvedAnnotationStyle = (storedAnnotationStyle ?? .default).normalized
            }
            serverAddress = stored.serverAddress
            token = stored.token
            hotKey = resolvedHotKey
            videoHotKey = resolvedVideoHotKey
            annotationStyle = resolvedAnnotationStyle
            language = stored.language ?? .system

            if stored.schemaVersion != Self.currentSchemaVersion
                || shouldMigrateLegacyF2
                || shouldMigrateDefaultLineWidths {
                try? store.save(StoredSettings(
                    schemaVersion: Self.currentSchemaVersion,
                    serverAddress: stored.serverAddress,
                    token: stored.token,
                    hotKeyCode: resolvedHotKey.keyCode,
                    hotKeyModifiers: resolvedHotKey.modifiers,
                    hotKeyLabel: resolvedHotKey.keyLabel,
                    videoHotKeyCode: resolvedVideoHotKey.keyCode,
                    videoHotKeyModifiers: resolvedVideoHotKey.modifiers,
                    videoHotKeyLabel: resolvedVideoHotKey.keyLabel,
                    annotationStyle: resolvedAnnotationStyle,
                    language: stored.language ?? .system
                ))
            }
        } else {
            serverAddress = ""
            token = ""
            hotKey = .default
            videoHotKey = .videoDefault
            annotationStyle = .default
            language = .system
        }
    }

    func save() throws {
        let configuration = try serviceConfiguration()
        try store.save(StoredSettings(
            schemaVersion: Self.currentSchemaVersion,
            serverAddress: configuration.baseURL.absoluteString,
            token: configuration.token,
            hotKeyCode: hotKey.keyCode,
            hotKeyModifiers: hotKey.modifiers,
            hotKeyLabel: hotKey.keyLabel,
            videoHotKeyCode: videoHotKey.keyCode,
            videoHotKeyModifiers: videoHotKey.modifiers,
            videoHotKeyLabel: videoHotKey.keyLabel,
            annotationStyle: annotationStyle,
            language: language
        ))
        serverAddress = configuration.baseURL.absoluteString
        token = configuration.token
    }

    func persistHotKey(_ value: HotKey) {
        hotKey = value
        do {
            let stored = try store.load()
            try store.save(StoredSettings(
                schemaVersion: Self.currentSchemaVersion,
                serverAddress: stored?.serverAddress ?? serverAddress,
                token: stored?.token ?? token,
                hotKeyCode: value.keyCode,
                hotKeyModifiers: value.modifiers,
                hotKeyLabel: value.keyLabel,
                videoHotKeyCode: stored?.videoHotKeyCode ?? videoHotKey.keyCode,
                videoHotKeyModifiers: stored?.videoHotKeyModifiers ?? videoHotKey.modifiers,
                videoHotKeyLabel: stored?.videoHotKeyLabel ?? videoHotKey.keyLabel,
                annotationStyle: stored?.annotationStyle ?? annotationStyle,
                language: stored?.language ?? language
            ))
        } catch {
            DiagnosticLog.record(error, phase: "save hotkey")
        }
    }

    func persistVideoHotKey(_ value: HotKey) {
        videoHotKey = value
        do {
            let stored = try store.load()
            try store.save(StoredSettings(
                schemaVersion: Self.currentSchemaVersion,
                serverAddress: stored?.serverAddress ?? serverAddress,
                token: stored?.token ?? token,
                hotKeyCode: stored?.hotKeyCode ?? hotKey.keyCode,
                hotKeyModifiers: stored?.hotKeyModifiers ?? hotKey.modifiers,
                hotKeyLabel: stored?.hotKeyLabel ?? hotKey.keyLabel,
                videoHotKeyCode: value.keyCode,
                videoHotKeyModifiers: value.modifiers,
                videoHotKeyLabel: value.keyLabel,
                annotationStyle: stored?.annotationStyle ?? annotationStyle,
                language: stored?.language ?? language
            ))
        } catch {
            DiagnosticLog.record(error, phase: "save video hotkey")
        }
    }

    func persistLanguage(_ value: AppLanguage) {
        language = value
        do {
            let stored = try store.load()
            try store.save(StoredSettings(
                schemaVersion: Self.currentSchemaVersion,
                serverAddress: stored?.serverAddress ?? serverAddress,
                token: stored?.token ?? token,
                hotKeyCode: stored?.hotKeyCode ?? hotKey.keyCode,
                hotKeyModifiers: stored?.hotKeyModifiers ?? hotKey.modifiers,
                hotKeyLabel: stored?.hotKeyLabel ?? hotKey.keyLabel,
                videoHotKeyCode: stored?.videoHotKeyCode ?? videoHotKey.keyCode,
                videoHotKeyModifiers: stored?.videoHotKeyModifiers ?? videoHotKey.modifiers,
                videoHotKeyLabel: stored?.videoHotKeyLabel ?? videoHotKey.keyLabel,
                annotationStyle: stored?.annotationStyle ?? annotationStyle,
                language: value
            ))
        } catch {
            DiagnosticLog.record(error, phase: "save language")
        }
    }

    func updateAnnotationStyle(_ value: AnnotationStylePreferences) {
        annotationStyle = value.normalized
        annotationStyleSaveTask?.cancel()
        annotationStyleSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistAnnotationStyle()
        }
    }

    func flushAnnotationStyle() {
        annotationStyleSaveTask?.cancel()
        annotationStyleSaveTask = nil
        persistAnnotationStyle()
    }

    private func persistAnnotationStyle() {
        do {
            let stored = try store.load()
            try store.save(StoredSettings(
                schemaVersion: Self.currentSchemaVersion,
                serverAddress: stored?.serverAddress ?? serverAddress,
                token: stored?.token ?? token,
                hotKeyCode: stored?.hotKeyCode ?? hotKey.keyCode,
                hotKeyModifiers: stored?.hotKeyModifiers ?? hotKey.modifiers,
                hotKeyLabel: stored?.hotKeyLabel ?? hotKey.keyLabel,
                videoHotKeyCode: stored?.videoHotKeyCode ?? videoHotKey.keyCode,
                videoHotKeyModifiers: stored?.videoHotKeyModifiers ?? videoHotKey.modifiers,
                videoHotKeyLabel: stored?.videoHotKeyLabel ?? videoHotKey.keyLabel,
                annotationStyle: annotationStyle,
                language: stored?.language ?? language
            ))
        } catch {
            DiagnosticLog.record(error, phase: "save annotation style")
        }
    }

    func serviceConfiguration() throws -> ServiceConfiguration {
        let url = try ServiceConfiguration.normalizeBaseURL(serverAddress)
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw SettingsError.missingToken
        }
        return ServiceConfiguration(baseURL: url, token: normalizedToken)
    }

    var hasUploadConfiguration: Bool {
        (try? serviceConfiguration()) != nil
    }
}
