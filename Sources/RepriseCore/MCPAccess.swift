import Foundation

/// Whether MCP clients may read this library. The file is signed with a key from the login
/// keychain, so another program cannot turn access on by editing it; unsigned or altered
/// settings read as access off.
public struct MCPAccess: Codable, Equatable, Sendable {
    public var enabled = false
    public var allowImages = false
    public init(enabled: Bool = false, allowImages: Bool = false) {
        self.enabled = enabled; self.allowImages = allowImages
    }

    private struct Stored: Codable {
        var enabled = false
        var allowImages = false
        var signature: String?
    }

    private var signedMessage: String { "Reprise MCP access v1 enabled=\(enabled) images=\(allowImages)" }

    public static func load(root: URL, keys: VaultKeys) throws -> MCPAccess {
        guard let stored = try stored(root: root) else { return MCPAccess() }
        let access = MCPAccess(enabled: stored.enabled, allowImages: stored.allowImages)
        guard let signature = stored.signature.flatMap({ Data(base64Encoded: $0) }),
              keys.isValidConsent(signature, for: access.signedMessage) else { return MCPAccess() }
        return access
    }

    public func save(root: URL, keys: VaultKeys) throws {
        let url = root.appendingPathComponent("mcp-access.json")
        let stored = Stored(enabled: enabled, allowImages: allowImages, signature: keys.consentSignature(signedMessage).base64EncodedString())
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Settings saved before encryption carried no signature. Reprise vouches for them once, while
    /// it converts the library, so a person's earlier choice survives the upgrade.
    public static func adoptUnsigned(root: URL, keys: VaultKeys) throws {
        guard let stored = try stored(root: root), stored.signature == nil else { return }
        try MCPAccess(enabled: stored.enabled, allowImages: stored.allowImages).save(root: root, keys: keys)
    }

    private static func stored(root: URL) throws -> Stored? {
        let url = root.appendingPathComponent("mcp-access.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 4096 else {
            throw MCPIntegrationError.message("Invalid MCP access settings. Review MCP in Reprise Settings.")
        }
        return try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
    }
}

public enum MCPIntegrationError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
