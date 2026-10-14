import Foundation

/// The ChatGPT sign-in of the Codex CLI, asked from Codex's own app server. Reprise never reads
/// Codex's files; the token lives in memory for one job and is never logged or written.
public enum ChatGPTSignIn {
    public enum Failure: LocalizedError, Equatable {
        case noCodex
        case notSignedIn
        case notChatGPT
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .noCodex: "Reprise reaches OpenAI with a ChatGPT plan through the Codex CLI. Install Codex, then sign in with ChatGPT."
            case .notSignedIn: "Codex is not signed in. Choose Sign In with ChatGPT in Settings, next to the OpenAI account."
            case .notChatGPT: "Codex is signed in with an API key, not a ChatGPT plan. Sign in to Codex with ChatGPT, or choose OpenAI API key as the account."
            case .unavailable(let detail): "Codex could not share its ChatGPT sign-in: \(detail) Updating Codex may help."
            }
        }
    }

    /// Codex in the order it is tried: the copy set for Codex in AI & Models, the usual install
    /// places, then the one inside the ChatGPT app.
    public static func codexExecutable(configured: String? = nil) -> URL? {
        if let configured, !configured.isEmpty {
            return configured.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: configured) ? URL(fileURLWithPath: configured) : nil
        }
        if let installed = AICommand.executable(AIProviderConfiguration(provider: .codex)) { return installed }
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        return FileManager.default.isExecutableFile(atPath: bundled) ? URL(fileURLWithPath: bundled) : nil
    }

    /// The access token of the ChatGPT sign-in, refreshed by Codex when it is about to expire.
    public static func token(codex: URL, timeout: Double = 30) async throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("reprise-codex-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = codex
        // Plugins stay off: the short-lived server would otherwise sync them into Codex's temp folder.
        process.arguments = ["app-server", "-c", "features.plugins=false"]
        process.currentDirectoryURL = root
        process.environment = ["HOME": fm.homeDirectoryForCurrentUser.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
                               "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "TMPDIR": root.path,
                               "LANG": "en_US.UTF-8", "TERM": "dumb"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // The handler keeps the process object until Codex exits, so it is reaped and leaves no zombie.
        process.terminationHandler = { finished in withExtendedLifetime(finished) {} }
        do { try process.run() } catch { throw Failure.unavailable(error.localizedDescription) }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        func send(_ message: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: message)
            line.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: line)
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": "reprise", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"]]])
        let reply: [String: Any] = try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if message["id"] as? Int == 1 {
                        try send(["jsonrpc": "2.0", "method": "initialized"])
                        try send(["jsonrpc": "2.0", "id": 2, "method": "getAuthStatus", "params": ["includeToken": true, "refreshToken": true]])
                    } else if message["id"] as? Int == 2 { return message }
                }
                throw Failure.unavailable("Codex ended before answering.")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Failure.unavailable("Codex did not answer in time.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        if let error = reply["error"] as? [String: Any] {
            throw Failure.unavailable((error["message"] as? String).map { "\($0)." } ?? "Codex refused the request.")
        }
        let result = reply["result"] as? [String: Any] ?? [:]
        guard let method = result["authMethod"] as? String else { throw Failure.notSignedIn }
        guard method.lowercased().contains("chatgpt") else { throw Failure.notChatGPT }
        guard let token = result["authToken"] as? String, !token.isEmpty else { throw Failure.notSignedIn }
        return token
    }
}

/// How Reprise reaches OpenAI's audio models: the ChatGPT plan the Codex CLI is signed in with, or
/// an OpenAI API key billed to the person's API account.
public enum OpenAIAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPT, apiKey
    public var id: String { rawValue }
    public var title: String { self == .chatGPT ? "ChatGPT plan, through Codex" : "OpenAI API key" }
}

/// A bearer for one job. It lives in memory only.
public struct OpenAICredential: Sendable {
    public let bearer: String
    public let access: OpenAIAccess

    public enum Failure: LocalizedError, Equatable {
        case noAPIKey
        public var errorDescription: String? { "No OpenAI API key is saved. Add one in AI & Models > API Keys." }
    }

    public static func resolve(_ access: OpenAIAccess, codexPath: String? = nil) async throws -> OpenAICredential {
        switch access {
        case .chatGPT:
            guard let codex = ChatGPTSignIn.codexExecutable(configured: codexPath) else { throw ChatGPTSignIn.Failure.noCodex }
            return OpenAICredential(bearer: try await ChatGPTSignIn.token(codex: codex), access: .chatGPT)
        case .apiKey:
            guard let key = APIKeys.load(.openAI) else { throw Failure.noAPIKey }
            return OpenAICredential(bearer: key, access: .apiKey)
        }
    }
}

/// OpenAI's Realtime API: a short-lived client secret is minted for each session with the person's
/// ChatGPT sign-in or API key, and the WebSocket carries it as its subprotocol.
public enum OpenAIRealtime {
    public struct Failure: LocalizedError {
        public let message: String
        public let code: String?
        public var errorDescription: String? { message }
        public init(_ message: String, code: String? = nil) { self.message = message; self.code = code }
    }

    /// A transcription session that takes 24 kHz 16-bit mono audio. With `vad`, OpenAI's voice
    /// detection splits speech into timed items; `delay` tunes how long a pause ends one.
    public static func transcriptionSession(model: String, language: String?, vad: Bool, silence: Int = 500, noiseReduction: String? = nil) -> [String: Any] {
        var transcription: [String: Any] = ["model": model]
        if let language, !language.isEmpty { transcription["language"] = language }
        var input: [String: Any] = ["format": ["type": "audio/pcm", "rate": 24_000], "transcription": transcription,
                                    "turn_detection": vad ? ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": silence] as [String: Any] : NSNull()]
        if let noiseReduction { input["noise_reduction"] = ["type": noiseReduction] }
        return ["type": "transcription", "audio": ["input": input]]
    }

    /// A live translation session: speech in any supported language becomes text, and speech, in
    /// `language`. With `transcribeInput`, the spoken words come back too.
    public static func translationSession(language: String, transcribeInput: Bool = false) -> [String: Any] {
        var audio: [String: Any] = ["output": ["language": language]]
        if transcribeInput { audio["input"] = ["transcription": ["model": OpenAIRealtime.liveTranscriptionModel]] }
        return ["model": "gpt-realtime-translate", "audio": audio]
    }

    public static let liveTranscriptionModel = "gpt-live-transcribe"

    /// Languages live translation writes, as OpenAI accepts them.
    public static let translationLanguages = ["af", "ar", "az", "be", "bg", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es", "et",
        "fa", "fi", "fr", "gl", "he", "hi", "hr", "hu", "hy", "id", "is", "it", "ja", "kk", "kn", "ko", "lt", "lv", "mi", "mk", "mr",
        "ms", "ne", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl", "sr", "sv", "sw", "ta", "th", "tl", "tr", "uk", "ur", "vi", "zh"]

    static let base = URL(string: "https://api.openai.com/v1/realtime")!

    /// Mints the client secret for one session. Translation has its own endpoint.
    public static func clientSecret(_ credential: OpenAICredential, session: [String: Any], translation: Bool = false) async throws -> String {
        let url = translation ? base.appendingPathComponent("translations/client_secrets") : base.appendingPathComponent("client_secrets")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["session": session])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let value = body["value"] as? String, (200..<300).contains(status) { return value }
        let error = body["error"] as? [String: Any]
        let detail = error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let apiKey = credential.access == .apiKey
        switch status {
        case 401, 403:
            throw Failure(apiKey ? "OpenAI did not accept the API key (\(detail)). Check it in AI & Models > API Keys."
                                 : "OpenAI did not accept the ChatGPT sign-in (\(detail)). Sign in to Codex again.", code: "unauthorized")
        case 429:
            throw Failure(apiKey ? "OpenAI refused the request for your API account: \(detail)" : "Your ChatGPT plan's limit was reached. Try again later. \(detail)", code: "rate_limit")
        default: throw Failure("OpenAI could not start a session: \(detail)", code: error?["code"] as? String ?? "status_\(status)")
        }
    }

    /// Opens the session's WebSocket. Translation sessions name their model in the address.
    public static func connect(secret: String, translation: Bool = false) -> RealtimeSocket {
        var components = URLComponents(string: translation ? "wss://api.openai.com/v1/realtime/translations" : "wss://api.openai.com/v1/realtime")!
        if translation { components.queryItems = [URLQueryItem(name: "model", value: "gpt-realtime-translate")] }
        return RealtimeSocket(url: components.url!, protocols: ["realtime", "openai-insecure-api-key.\(secret)"])
    }

    /// 16-bit little-endian PCM of samples in -1...1.
    public static func pcm16<Samples: Collection>(_ samples: Samples) -> Data where Samples.Element == Float {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                out[index] = Int16(max(-1, min(1, sample)) * 32_767).littleEndian
            }
        }
        return data
    }
}

/// One Realtime WebSocket: JSON events out, decoded events in.
public final class RealtimeSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    public let events: AsyncThrowingStream<[String: Any], Error>
    private let continuation: AsyncThrowingStream<[String: Any], Error>.Continuation

    init(url: URL, protocols: [String]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url, protocols: protocols)
        // Audio for a long recording can exceed the default 1 MB message limit only on the way in; replies stay small.
        task.maximumMessageSize = 16 * 1024 * 1024
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
        super.init()
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = nil
                }
                if let data, let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.continuation.yield(event) }
                self.receive()
            case .failure(let error):
                if self.task.closeCode != .invalid { self.continuation.finish() }
                else { self.continuation.finish(throwing: OpenAIRealtime.Failure("The connection to OpenAI ended: \(error.localizedDescription)")) }
            }
        }
    }

    public func send(_ event: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
        session.finishTasksAndInvalidate()
    }
}
