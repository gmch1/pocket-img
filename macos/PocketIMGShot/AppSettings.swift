import Combine
import Foundation

private struct StoredSettings: Codable {
    let serverAddress: String
    let token: String
    let hotKeyCode: UInt32
    let hotKeyModifiers: UInt
    let hotKeyLabel: String
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

enum SettingsError: LocalizedError {
    case invalidServerAddress
    case serverAddressHasPath
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return "服务器地址必须是完整的 HTTP 或 HTTPS 地址。"
        case .serverAddressHasPath:
            return "服务器地址不能包含路径，请只填写协议、域名和端口。"
        case .missingToken:
            return "Token 不能为空。"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let serverAddress = "serverAddress"
        static let token = "token"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
    }

    @Published var serverAddress: String
    @Published var token: String
    @Published var hotKey: HotKey
    @Published var hotKeyRegistrationError = ""

    private let defaults: UserDefaults
    private let store: SettingsStore

    init(defaults: UserDefaults = .standard, settingsURL: URL? = nil) {
        self.defaults = defaults
        store = SettingsStore(fileURL: settingsURL ?? SettingsStore.defaultURL)

        if let stored = try? store.load() {
            serverAddress = stored.serverAddress
            token = stored.token
            hotKey = HotKey(
                keyCode: stored.hotKeyCode,
                modifiers: stored.hotKeyModifiers,
                keyLabel: stored.hotKeyLabel
            )
        } else {
            serverAddress = defaults.string(forKey: Keys.serverAddress) ?? ""
            token = defaults.string(forKey: Keys.token) ?? ""
            if defaults.object(forKey: Keys.hotKeyCode) != nil {
                hotKey = HotKey(
                    keyCode: UInt32(defaults.integer(forKey: Keys.hotKeyCode)),
                    modifiers: (defaults.object(forKey: Keys.hotKeyModifiers) as? NSNumber)?.uintValue ?? 0,
                    keyLabel: defaults.string(forKey: Keys.hotKeyLabel) ?? HotKey.default.keyLabel
                )
            } else {
                hotKey = .default
            }
        }
    }

    func save() throws {
        let configuration = try serviceConfiguration()
        defaults.set(configuration.baseURL.absoluteString, forKey: Keys.serverAddress)
        defaults.set(configuration.token, forKey: Keys.token)
        defaults.set(Int(hotKey.keyCode), forKey: Keys.hotKeyCode)
        defaults.set(NSNumber(value: hotKey.modifiers), forKey: Keys.hotKeyModifiers)
        defaults.set(hotKey.keyLabel, forKey: Keys.hotKeyLabel)
        try store.save(StoredSettings(
            serverAddress: configuration.baseURL.absoluteString,
            token: configuration.token,
            hotKeyCode: hotKey.keyCode,
            hotKeyModifiers: hotKey.modifiers,
            hotKeyLabel: hotKey.keyLabel
        ))
        serverAddress = configuration.baseURL.absoluteString
        token = configuration.token
    }

    func serviceConfiguration() throws -> ServiceConfiguration {
        let url = try ServiceConfiguration.normalizeBaseURL(serverAddress)
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw SettingsError.missingToken
        }
        return ServiceConfiguration(baseURL: url, token: normalizedToken)
    }
}
