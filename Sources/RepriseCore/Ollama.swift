import Foundation

/// Models served by a local Ollama on this Mac. Requests go only to the loopback address, and the
/// chat call sends no tool definitions, so the model can only answer.
public enum Ollama {
    static let base = URL(string: "http://127.0.0.1:11434")!
    /// The context Reprise asks Ollama for; models default to less, which truncates the evidence.
    static let contextTokens = 12_288
    /// Small models that fit a 16 GB Mac. EXAONE is LG's Korean-English model.
    public static let suggestedModels: [(id: String, name: String)] = [
        ("exaone3.5:2.4b", "EXAONE 3.5 2.4B, Korean and English, 1.6 GB"),
        ("qwen3.5:4b", "Qwen 3.5 4B, many languages, 3.3 GB"),
        ("gemma3:4b", "Gemma 3 4B, many languages, 3.4 GB")
    ]

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static var appInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Ollama.app") }

    /// The running server's version, or nil when Ollama is not running.
    public static func version() async -> String? {
        guard let object = try? await json("api/version", timeout: 2) else { return nil }
        return object["version"] as? String
    }

    public static func models() async -> [String] {
        guard let object = try? await json("api/tags", timeout: 4), let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    static func capabilities(_ model: String) async -> [String] {
        let object = try? await json("api/show", body: ["model": model], timeout: 6)
        return object?["capabilities"] as? [String] ?? []
    }

    static func generate(input: Data, schema: String, systemPrompt: String, model: String, timeout: Double) async throws -> AIJSONResult {
        let installed = await models()
        guard await version() != nil else { throw AIProviderError.unavailable }
        let model = model.isEmpty ? (installed.first ?? "") : model
        guard !model.isEmpty, installed.contains(model) else { throw AIProviderError.modelMissing }
        guard let format = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else { throw AIProviderError.invalidInput }
        var body: [String: Any] = [
            "model": model, "stream": false, "format": format,
            "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": String(decoding: input, as: UTF8.self)]],
            "options": ["temperature": 0.2, "num_ctx": contextTokens]
        ]
        // Thinking models answer faster without a hidden reasoning pass; others reject the flag.
        if await capabilities(model).contains("thinking") { body["think"] = false }
        let start = Date()
        let object: [String: Any]
        do { object = try await json("api/chat", body: body, timeout: min(180, max(5, timeout))) }
        catch let error as URLError where error.code == .timedOut { throw AIProviderError.timedOut }
        catch is CancellationError { throw AIProviderError.cancelled }
        if object["error"] != nil { throw AIProviderError.providerFailed }
        guard let message = object["message"] as? [String: Any], message["tool_calls"] == nil else { throw AIProviderError.toolAttempt }
        guard let content = message["content"] as? String,
              let payload = AIResponseParser.jsonObject(in: content) else { throw AIProviderError.invalidResponse }
        let usage = UsageEntry(provider: AIProviderKind.ollama.rawValue, model: model,
                               inputTokens: object["prompt_eval_count"] as? Int, outputTokens: object["eval_count"] as? Int,
                               durationSeconds: Date().timeIntervalSince(start))
        return AIJSONResult(payload: payload, usage: usage,
                            context: usage.inputTokens.map { AIContextUse(tokens: $0, window: contextTokens) })
    }

    /// Downloads a model, reporting the completed fraction when the server knows the size.
    public static func pull(_ model: String, progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        guard AICommand.validModel(model), !model.isEmpty else { throw AIProviderError.invalidInput }
        var request = URLRequest(url: base.appendingPathComponent("api/pull"), timeoutInterval: 3_600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AIProviderError.providerFailed }
        for try await line in bytes.lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = event["error"] as? String { throw PullFailure(message: error) }
            let status = event["status"] as? String ?? ""
            let total = (event["total"] as? NSNumber)?.doubleValue, completed = (event["completed"] as? NSNumber)?.doubleValue
            progress(total.flatMap { total in completed.map { total > 0 ? $0 / total : 0 } }, status)
            if status == "success" { return }
        }
    }

    public struct PullFailure: LocalizedError {
        let message: String
        public var errorDescription: String? { "Ollama could not download the model: \(message)" }
    }

    private static func json(_ path: String, body: [String: Any]? = nil, timeout: Double) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await session.data(for: request)
        guard data.count <= 8 * 1024 * 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidResponse
        }
        return object
    }
}
