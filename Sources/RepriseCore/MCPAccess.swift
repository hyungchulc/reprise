import Foundation

public struct MCPAccess: Codable, Equatable, Sendable {
    public var enabled = false
    public var allowImages = false
    public init(enabled: Bool = false, allowImages: Bool = false) {
        self.enabled = enabled; self.allowImages = allowImages
    }

    public static func load(root: URL) throws -> MCPAccess {
        let url = root.appendingPathComponent("mcp-access.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return MCPAccess() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 4096 else {
            throw MCPIntegrationError.message("Invalid MCP access settings. Review MCP in Reprise Settings.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(root: URL) throws {
        let url = root.appendingPathComponent("mcp-access.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum MCPIntegrationError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
