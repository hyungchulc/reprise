import Foundation
import MCP
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

/// An MCP server the person adds for the meeting assistant: a command Reprise starts, or an address.
public struct MCPServerSetting: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// A command line, such as `npx -y some-mcp-server`; empty when the server is an address.
    public var command: String
    /// A streamable HTTP endpoint; empty when the server is a command.
    public var url: String
    public var enabled: Bool
    /// Tools turned on or off by hand. The rest are on when the server marks them read-only.
    public var toolChoices: [String: Bool]

    public init(name: String = "", command: String = "", url: String = "", enabled: Bool = true, toolChoices: [String: Bool] = [:]) {
        self.name = name; self.command = command; self.url = url; self.enabled = enabled; self.toolChoices = toolChoices
    }

    public var isCommand: Bool { !command.trimmingCharacters(in: .whitespaces).isEmpty }

    public func allows(_ tool: MCPToolInfo) -> Bool { toolChoices[tool.name] ?? tool.readOnly }
}

/// What a server needs that must not sit in preferences: environment variables for a command, or
/// a bearer token for an address. It lives in the login keychain.
public struct MCPServerSecrets: Codable, Equatable, Sendable {
    public var environment: [String: String]
    public var token: String
    public init(environment: [String: String] = [:], token: String = "") { self.environment = environment; self.token = token }
}

public struct MCPToolInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    /// The JSON schema of the arguments.
    public let inputSchema: String
    /// The server says the tool changes nothing. Reprise only uses this to choose which tools start on.
    public let readOnly: Bool
}

public struct MCPToolFailure: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Connections to the person's MCP servers while the meeting assistant runs. Commands run as the
/// person, the way other MCP apps start them.
public actor MCPToolHub {
    private struct Connection {
        let client: Client
        let process: Process?
        let errors: MCPErrorLog?
    }
    private var connections: [UUID: Connection] = [:]

    public init() {}

    /// Connects to a server, replacing an earlier connection to it, and lists its tools.
    public func connect(_ server: MCPServerSetting, secrets: MCPServerSecrets, timeout: Double = 30) async throws -> [MCPToolInfo] {
        await disconnect(server.id)
        let client = Client(name: "Reprise", version: "1")
        var process: Process?
        var errors: MCPErrorLog?
        let transport: any Transport
        if server.isCommand {
            let started = try Self.start(server.command, environment: secrets.environment)
            process = started.process; errors = started.errors
            transport = StdioTransport(input: FileDescriptor(rawValue: started.output.fileHandleForReading.fileDescriptor),
                                       output: FileDescriptor(rawValue: started.input.fileHandleForWriting.fileDescriptor))
        } else {
            guard let url = URL(string: server.url.trimmingCharacters(in: .whitespaces)), let host = url.host,
                  url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host) else {
                throw MCPToolFailure("Enter an https address, or an http address on this Mac.")
            }
            let token = secrets.token.trimmingCharacters(in: .whitespacesAndNewlines)
            transport = HTTPClientTransport(endpoint: url, configuration: .ephemeral, streaming: true, requestModifier: { request in
                guard !token.isEmpty else { return request }
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            })
        }
        do {
            let tools = try await Self.within(timeout, "\(server.name) did not answer within \(Int(timeout)) seconds.") {
                _ = try await client.connect(transport: transport)
                var tools: [Tool] = [], cursor: String?
                repeat {
                    let page = try await client.listTools(cursor: cursor)
                    tools += page.tools; cursor = page.nextCursor
                } while cursor != nil && tools.count < 500
                return tools
            }
            connections[server.id] = Connection(client: client, process: process, errors: errors)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return tools.map { tool in
                let schema = (try? encoder.encode(tool.inputSchema)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"type":"object"}"#
                return MCPToolInfo(name: tool.name, description: tool.description ?? tool.title ?? "", inputSchema: schema,
                                   readOnly: tool.annotations.readOnlyHint == true)
            }
        } catch {
            await client.disconnect()
            Self.stop(process)
            let detail = errors?.last.map { " \($0)" } ?? ""
            if let failure = error as? MCPToolFailure { throw MCPToolFailure(failure.message + detail) }
            throw MCPToolFailure("\(server.name) could not start: \(error.localizedDescription)\(detail)")
        }
    }

    /// Calls a tool with the model's JSON arguments and returns its text for the model.
    public func call(_ server: UUID, tool: String, arguments: String, timeout: Double = 60) async throws -> String {
        guard let connection = connections[server] else { throw MCPToolFailure("The server is not connected.") }
        let values = (try? JSONDecoder().decode([String: Value].self, from: Data(arguments.utf8))) ?? [:]
        let result = try await Self.within(timeout, "The tool did not finish within \(Int(timeout)) seconds.") {
            try await connection.client.callTool(name: tool, arguments: values)
        }
        let text = result.content.map { content -> String in
            switch content {
            case .text(let text, _, _): text
            case .image: "[an image]"
            case .audio: "[audio]"
            case .resource(let resource, _, _): resource.text ?? "[\(resource.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _): "\(name): \(uri)"
            }
        }.joined(separator: "\n")
        let bounded = text.count > 8_000 ? String(text.prefix(8_000)) + "\n[cut off]" : text
        return result.isError == true ? "The tool reported an error: \(bounded)" : bounded
    }

    public func disconnect(_ id: UUID) async {
        guard let connection = connections.removeValue(forKey: id) else { return }
        await connection.client.disconnect()
        Self.stop(connection.process)
    }

    public func disconnectAll() async {
        for id in Array(connections.keys) { await disconnect(id) }
    }

    // MARK: Commands

    private static func start(_ command: String, environment: [String: String]) throws -> (process: Process, input: Pipe, output: Pipe, errors: MCPErrorLog) {
        let words = try commandWords(command)
        guard let first = words.first else { throw MCPToolFailure("Enter the command that starts the server.") }
        let path = searchPath()
        guard let program = locate(first, in: path) else {
            throw MCPToolFailure("\(first) was not found. Install it, or enter its full path, such as /opt/homebrew/bin/\(first).")
        }
        let process = Process()
        process.executableURL = program
        process.arguments = Array(words.dropFirst())
        let home = FileManager.default.homeDirectoryForCurrentUser
        process.currentDirectoryURL = home
        process.environment = ["HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(), "PATH": path.joined(separator: ":"),
                               "LANG": "en_US.UTF-8", "TMPDIR": FileManager.default.temporaryDirectory.path]
            .merging(environment) { _, new in new }
        let input = Pipe(), output = Pipe(), errorPipe = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errorPipe
        let errors = MCPErrorLog()
        // A server that writes much to stderr must not stall on a full pipe; the end is kept for messages.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errors.append(data) }
        }
        do { try process.run() } catch { throw MCPToolFailure("\(first) could not start: \(error.localizedDescription)") }
        return (process, input, output, errors)
    }

    private static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }

    /// Splits a command line the way a shell would for plain words and quotes, without running a shell.
    static func commandWords(_ line: String) throws -> [String] {
        var words: [String] = [], current = "", quote: Character?, escaped = false, started = false
        for character in line {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; started = true; continue }
            if character.isWhitespace {
                if started { words.append(current); current = ""; started = false }
                continue
            }
            current.append(character); started = true
        }
        guard quote == nil, !escaped else { throw MCPToolFailure("The command has an unclosed quote.") }
        if started { words.append(current) }
        return words
    }

    /// Folders where package runners such as npx, uvx and bunx usually live, since apps get a short PATH.
    static func searchPath() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
                       "\(home)/.volta/bin", "\(home)/.npm-global/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let newest = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first
            if let newest { folders.insert("\(nvm)/\(newest)/bin", at: 2) }
        }
        return folders
    }

    static func locate(_ program: String, in path: [String]) -> URL? {
        if program.contains("/") {
            let expanded = (program as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        return path.map { "\($0)/\(program)" }.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private static func within<T: Sendable>(_ seconds: Double, _ message: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPToolFailure(message)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MCPToolFailure(message) }
            return first
        }
    }
}

/// The last lines a server wrote to stderr, for its error messages.
final class MCPErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        text += String(decoding: data, as: UTF8.self)
        if text.count > 2_000 { text = String(text.suffix(2_000)) }
    }
    var last: String? {
        lock.lock(); defer { lock.unlock() }
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
    }
}
