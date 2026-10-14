import Foundation
import RepriseCore
import RepriseMCPKit
import Security

/// Environment variables and tokens of the person's MCP servers, one login keychain item per server.
enum MCPServerKeychain {
    static let service = "local.aria.reprise.mcp-server"

    static func load(_ id: UUID) -> MCPServerSecrets {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secrets = try? JSONDecoder().decode(MCPServerSecrets.self, from: data) else { return MCPServerSecrets() }
        return secrets
    }

    /// Saves the secrets, or removes the item when there are none.
    static func save(_ secrets: MCPServerSecrets, for id: UUID, name: String) throws {
        guard !secrets.environment.isEmpty || !secrets.token.isEmpty else { remove(id); return }
        let data = try JSONEncoder().encode(secrets)
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData: data, kSecAttrLabel: "Reprise MCP Server (\(name))"] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw APIKeys.Failure.keychain(update) }
        var item = match
        item[kSecValueData] = data
        item[kSecAttrLabel] = "Reprise MCP Server (\(name))"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIKeys.Failure.keychain(status) }
    }

    static func remove(_ id: UUID) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString] as CFDictionary)
    }
}
