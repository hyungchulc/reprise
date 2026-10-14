import Foundation

/// Short answers as text from OpenAI's Realtime API, a few characters at a time, with tools the
/// app runs itself. One session stays open while it is used. The ChatGPT sign-in Codex shares
/// works here, where the Responses API refuses it.
public actor RealtimeAnswers {
    public enum Event: Sendable, Equatable {
        case text(String)
        /// The model calls a tool; `arguments` is its JSON.
        case tool(name: String, arguments: String)
    }

    public struct Tool: Sendable {
        public let name: String
        public let description: String
        /// The JSON schema of the arguments.
        public let parameters: String
        /// Runs the tool with the model's JSON arguments and returns what the model reads.
        public let run: @Sendable (String) async -> String
        public init(name: String, description: String, parameters: String, run: @escaping @Sendable (String) async -> String) {
            self.name = name; self.description = description; self.parameters = parameters; self.run = run
        }
    }

    public static let defaultModel = "gpt-realtime"

    private let credential: @Sendable () async throws -> OpenAICredential
    private let model: String
    private var instructions: String
    private var tools: [Tool]
    /// Each answer starts with a tool call, so it rests on what the tools find rather than on guesses.
    private let toolFirst: Bool
    private var socket: RealtimeSocket?
    private var reader: Task<Void, Never>?
    private var connected: CheckedContinuation<Void, Error>?
    /// The session accepts questions.
    private var ready = false
    private var connecting: Task<Void, Error>?
    private var pending: Pending?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Conversation items of earlier exchanges, oldest first; only the last two stay for follow-ups.
    private var exchanges: [[String]] = []
    private var trims = 0

    private struct Pending {
        let continuation: AsyncThrowingStream<Event, Error>.Continuation
        var calls: [(id: String, name: String, arguments: String)] = []
        var items: [String] = []
    }

    public init(model: String = RealtimeAnswers.defaultModel, instructions: String, tools: [Tool], toolFirst: Bool = false,
                credential: @escaping @Sendable () async throws -> OpenAICredential) {
        self.model = model; self.instructions = instructions; self.tools = tools; self.credential = credential
        self.toolFirst = toolFirst
    }

    /// Opens the session ahead of the first question, so it starts answering at once.
    public func prepare() async {
        try? await ensureConnected()
    }

    /// One connection at a time; callers while it opens wait for it.
    private func ensureConnected() async throws {
        if ready, socket != nil { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    /// Answers one prompt; a prompt asked while another is answered waits its turn.
    public nonisolated func answer(_ prompt: String) -> AsyncThrowingStream<Event, Error> {
        let (stream, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
        let task = Task { await self.begin(prompt, continuation) }
        continuation.onTermination = { termination in if case .cancelled = termination { task.cancel() } }
        return stream
    }

    /// Changes the instructions and tools, for the open session too, such as when MCP servers connect.
    public func update(instructions: String, tools: [Tool]) async {
        self.instructions = instructions
        self.tools = tools
        guard ready, let socket else { return }
        var session = Self.session(model: model, instructions: instructions, tools: tools)
        session.removeValue(forKey: "model")
        if tools.isEmpty { session["tools"] = [Any](); session["tool_choice"] = "none" }
        try? await socket.send(["type": "session.update", "session": session])
    }

    public func close() {
        reader?.cancel(); reader = nil
        socket?.close(); socket = nil; ready = false
        pending?.continuation.finish(throwing: CancellationError()); pending = nil
        exchanges = []
        waiting.forEach { $0.resume() }; waiting = []
    }

    /// The session settings for `client_secrets`.
    public static func session(model: String, instructions: String, tools: [Tool]) -> [String: Any] {
        var session: [String: Any] = ["type": "realtime", "model": model, "output_modalities": ["text"], "instructions": instructions]
        let definitions: [[String: Any]] = tools.compactMap { tool in
            guard let schema = try? JSONSerialization.jsonObject(with: Data(tool.parameters.utf8)) else { return nil }
            return ["type": "function", "name": tool.name, "description": tool.description, "parameters": schema]
        }
        if !definitions.isEmpty { session["tools"] = definitions; session["tool_choice"] = "auto" }
        return session
    }

    private func begin(_ prompt: String, _ continuation: AsyncThrowingStream<Event, Error>.Continuation) async {
        while pending != nil { await withCheckedContinuation { waiting.append($0) } }
        guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
        pending = Pending(continuation: continuation)
        do {
            try await ensureConnected()
            try await socket?.send(["type": "conversation.item.create",
                                    "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]])
            try await socket?.send(toolFirst && !tools.isEmpty ? ["type": "response.create", "response": ["tool_choice": "required"]] : ["type": "response.create"])
        } catch {
            finish(throwing: error)
        }
    }

    private func connect() async throws {
        let credential = try await credential()
        let secret = try await OpenAIRealtime.clientSecret(credential, session: Self.session(model: model, instructions: instructions, tools: tools))
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        let socket = RealtimeSocket(url: components.url!, protocols: ["realtime", "openai-insecure-api-key.\(secret)"])
        self.socket = socket
        reader = Task { [weak self] in
            do {
                for try await event in socket.events { await self?.route(event) }
                await self?.ended(OpenAIRealtime.Failure("OpenAI ended the answer session."))
            } catch {
                await self?.ended(error)
            }
        }
        try await withCheckedThrowingContinuation { connected = $0 }
    }

    private func route(_ event: [String: Any]) async {
        let type = event["type"] as? String ?? ""
        switch type {
        case "session.created":
            ready = true
            connected?.resume(); connected = nil
        case "conversation.item.added", "conversation.item.created":
            if let id = (event["item"] as? [String: Any])?["id"] as? String { pending?.items.append(id) }
        case "response.output_text.delta", "response.text.delta":
            if let delta = event["delta"] as? String { pending?.continuation.yield(.text(delta)) }
        case "response.function_call_arguments.done":
            let call = (id: event["call_id"] as? String ?? "", name: event["name"] as? String ?? "", arguments: event["arguments"] as? String ?? "{}")
            pending?.calls.append(call)
            pending?.continuation.yield(.tool(name: call.name, arguments: call.arguments))
        case "response.done":
            await responseDone(event["response"] as? [String: Any] ?? [:])
        case "error":
            let error = event["error"] as? [String: Any] ?? [:]
            // Removing an old item that is already gone does not concern the answer.
            if (error["event_id"] as? String)?.hasPrefix("trim") == true { return }
            let failure = OpenAIRealtime.Failure("OpenAI: \(error["message"] as? String ?? "an error occurred")", code: error["code"] as? String)
            if connected != nil { connected?.resume(throwing: failure); connected = nil } else { finish(throwing: failure) }
        default: break
        }
    }

    /// A response that called tools continues with their results; any other ends the answer.
    private func responseDone(_ response: [String: Any]) async {
        guard var current = pending else { return }
        if response["status"] as? String == "failed" {
            let details = (response["status_details"] as? [String: Any])?["error"] as? [String: Any]
            finish(throwing: OpenAIRealtime.Failure("OpenAI could not answer: \(details?["message"] as? String ?? "the response failed")."))
            return
        }
        guard !current.calls.isEmpty else { finish(); return }
        // Tools that went away since the session began are answered as gone.
        let calls = current.calls
        current.calls = []
        pending = current
        do {
            for call in calls {
                let output = await tools.first(where: { $0.name == call.name })?.run(call.arguments) ?? "No such tool."
                try await socket?.send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": call.id, "output": output]])
            }
            try await socket?.send(["type": "response.create"])
        } catch {
            finish(throwing: error)
        }
    }

    private func finish(throwing error: Error? = nil) {
        guard let current = pending else { return }
        pending = nil
        if let error { current.continuation.finish(throwing: error) } else { current.continuation.finish() }
        // The session keeps the last two exchanges, so a follow-up question has its context.
        exchanges.append(current.items)
        while exchanges.count > 2 {
            for item in exchanges.removeFirst() {
                trims += 1
                let event: [String: Any] = ["type": "conversation.item.delete", "item_id": item, "event_id": "trim\(trims)"]
                Task { [socket] in try? await socket?.send(event) }
            }
        }
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }

    private func ended(_ error: Error) {
        socket = nil; reader = nil; exchanges = []; ready = false
        connected?.resume(throwing: error); connected = nil
        finish(throwing: error)
    }
}
