import Foundation

public enum MCPClientKind: String, CaseIterable, Identifiable, Sendable {
    case claudeDesktop = "Claude Desktop", claudeCode = "Claude Code", codex = "Codex", cursor = "Cursor"
    public var id: String { rawValue }
    public func configurationURL(home: URL) -> URL {
        switch self {
        case .claudeDesktop: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .claudeCode: home.appendingPathComponent(".claude.json")
        case .cursor: home.appendingPathComponent(".cursor/mcp.json")
        case .codex: home.appendingPathComponent(".codex/config.toml")
        }
    }
}

public enum MCPClientState: Equatable, Sendable {
    case installed, absent, conflict, unavailable
    public var message: String {
        switch self {
        case .installed: "Configuration installed"
        case .absent: "Not configured"
        case .conflict: "Another reprise entry exists"
        case .unavailable: "Cannot inspect configuration"
        }
    }
}

/// Edits only the named entry; client startup and consent stay under user control.
public actor MCPClientInstaller {
    public static let serverName = "reprise"
    private let home: URL
    private let helper: URL
    private let vault: URL
    private let codexExecutable: URL?

    public init(helper: URL, vault: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, codexExecutable: URL? = nil) {
        self.helper = helper; self.vault = vault; self.home = home; self.codexExecutable = codexExecutable
    }

    private var entry: [String: Any] { ["command": helper.path, "args": ["--vault", vault.path]] }

    public func configuration() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": [Self.serverName: entry]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    public func status(_ client: MCPClientKind) async -> MCPClientState {
        do {
            if client == .codex {
                guard resolvedCodexExecutable != nil else { return .unavailable }
                if !FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) { return .absent }
                let output = try await codex(["mcp", "list", "--json"])
                guard output.exitCode == 0, let servers = try JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]] else { return .unavailable }
                guard let server = servers.first(where: { $0["name"] as? String == Self.serverName }),
                      let transport = server["transport"] as? [String: Any] else {
                    return servers.contains(where: { $0["name"] as? String == Self.serverName }) ? .conflict : .absent
                }
                return owns(transport) ? .installed : .conflict
            }
            let (_, json) = try readJSON(client.configurationURL(home: home))
            return try state(json)
        } catch { return .unavailable }
    }

    public func setInstalled(_ installed: Bool, for client: MCPClientKind) async throws {
        if installed && !FileManager.default.isExecutableFile(atPath: helper.path) {
            throw MCPIntegrationError.message("The bundled MCP helper is missing. Install a packaged Reprise app first.")
        }
        if client == .codex {
            let current = await status(client)
            guard current == .installed || current == .absent else { throw MCPIntegrationError.message(current.message) }
            if (current == .installed) == installed { return }
            try backupIfPresent(client.configurationURL(home: home))
            if installed {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let args = installed ? ["mcp", "add", Self.serverName, "--", helper.path, "--vault", vault.path] : ["mcp", "remove", Self.serverName]
            let output = try await codex(args)
            guard output.exitCode == 0, await status(client) == (installed ? .installed : .absent) else {
                throw MCPIntegrationError.message("Codex did not confirm the configuration change. Review its MCP settings.")
            }
            return
        }
        let url = client.configurationURL(home: home)
        let (before, original) = try readJSON(url)
        let current = try state(original)
        guard current == .installed || current == .absent else { throw MCPIntegrationError.message(current.message) }
        if (current == .installed) == installed { return }
        var json = original
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        if installed { servers[Self.serverName] = entry } else { servers.removeValue(forKey: Self.serverName) }
        json["mcpServers"] = servers
        let encoded = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try readJSON(url).0 == before else { throw MCPIntegrationError.message("The client changed its settings. Try again after closing it.") }
        try backupIfPresent(url)
        try encoded.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try state(readJSON(url).1) == (installed ? .installed : .absent) else {
            throw MCPIntegrationError.message("Configuration verification failed.")
        }
    }

    public func checkConnection() async throws -> String {
        let output = try await AIProcessRunner.run(executable: helper, arguments: ["--vault", vault.path, "--check"], input: Data(), timeout: 10, outputLimit: 4_096)
        guard output.exitCode == 0 else { throw MCPIntegrationError.message("Connection check failed. Enable MCP access and open this library in Reprise first.") }
        return "Helper and read-only library verified. Restart the client to load its MCP configuration."
    }

    private func owns(_ value: [String: Any]) -> Bool {
        value["command"] as? String == helper.path && value["args"] as? [String] == ["--vault", vault.path]
    }

    private func state(_ json: [String: Any]) throws -> MCPClientState {
        guard let value = json["mcpServers"] else { return .absent }
        guard let servers = value as? [String: Any] else { throw MCPIntegrationError.message("Invalid mcpServers object. Existing settings were not changed.") }
        guard let existing = servers[Self.serverName] else { return .absent }
        guard let entry = existing as? [String: Any], owns(entry) else { return .conflict }
        return .installed
    }

    private func readJSON(_ url: URL) throws -> (Data?, [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, [:]) }
        try validateFile(url)
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPIntegrationError.message("Client settings must contain a JSON object. Existing settings were not changed.")
        }
        return (data, json)
    }

    private func validateFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= 8 * 1024 * 1024 else {
            throw MCPIntegrationError.message("Client settings are a link, too large, or not a regular file. Use manual configuration.")
        }
    }

    private func backupIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try validateFile(url)
        let backup = url.appendingPathExtension("reprise-backup-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: url, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private var resolvedCodexExecutable: URL? {
        let url = codexExecutable ?? AICommand.executable(AIProviderConfiguration(provider: .codex))
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private func codex(_ args: [String]) async throws -> AIProcessOutput {
        guard let executable = resolvedCodexExecutable else {
            throw MCPIntegrationError.message("Codex CLI was not found. Use Copy Configuration for a manual connection.")
        }
        return try await AIProcessRunner.run(executable: executable, arguments: args, input: Data(), timeout: 15, outputLimit: 1024 * 1024,
            environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path])
    }
}
