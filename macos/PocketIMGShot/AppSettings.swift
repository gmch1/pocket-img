import Combine
import Foundation

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
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
    }

    @Published var serverAddress: String
    @Published var token: String
    @Published var hotKey: HotKey
    @Published var hotKeyRegistrationError = ""

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        serverAddress = defaults.string(forKey: Keys.serverAddress) ?? ""
        token = (try? keychain.loadToken()) ?? ""

        if defaults.object(forKey: Keys.hotKeyCode) != nil {
            hotKey = HotKey(
                keyCode: UInt32(defaults.integer(forKey: Keys.hotKeyCode)),
                modifiers: (defaults.object(forKey: Keys.hotKeyModifiers) as? NSNumber)?.uintValue ?? 0,
                keyLabel: defaults.string(forKey: Keys.hotKeyLabel) ?? "F2"
            )
        } else {
            hotKey = .default
        }
    }

    func save() throws {
        let configuration = try serviceConfiguration()
        defaults.set(configuration.baseURL.absoluteString, forKey: Keys.serverAddress)
        defaults.set(Int(hotKey.keyCode), forKey: Keys.hotKeyCode)
        defaults.set(NSNumber(value: hotKey.modifiers), forKey: Keys.hotKeyModifiers)
        defaults.set(hotKey.keyLabel, forKey: Keys.hotKeyLabel)
        try keychain.saveToken(configuration.token)
        serverAddress = configuration.baseURL.absoluteString
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
