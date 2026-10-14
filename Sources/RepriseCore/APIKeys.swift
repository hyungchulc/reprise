import Foundation
import Security

/// Services Reprise can reach with the person's own API key, billed to their API account.
public enum APIKeyProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai", anthropic, gemini
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .gemini: "Google Gemini" }
    }
    /// Where a key is made.
    public var consoleURL: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}

/// API keys in the login keychain, one item per service. Nothing else stores or logs them.
public enum APIKeys {
    static let service = "local.aria.reprise.api-key"

    public static func save(_ key: String, for provider: APIKeyProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512, !key.contains(where: { $0.isWhitespace }) else { throw Failure.invalid }
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: provider.rawValue]
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData: Data(key.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.keychain(update) }
        var item = match
        item[kSecValueData] = Data(key.utf8)
        item[kSecAttrLabel] = "Reprise API Key (\(provider.displayName))"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public static func load(_ provider: APIKeyProvider) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: provider.rawValue,
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a key is saved, without reading it.
    public static func has(_ provider: APIKeyProvider) -> Bool {
        SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: provider.rawValue,
                             kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, nil) == errSecSuccess
    }

    public static func remove(_ provider: APIKeyProvider) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: provider.rawValue] as CFDictionary)
    }

    public enum Failure: LocalizedError {
        case invalid
        case keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .invalid: "That does not look like an API key."
            case .keychain(let status): "The key could not be saved in the login keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"
            }
        }
    }
}
