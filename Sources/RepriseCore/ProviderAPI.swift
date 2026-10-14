import Foundation

/// Search, summaries and meeting answers with the person's own API key, billed by the token to
/// their API account. A request carries the instructions and the evidence as one message and asks
/// for JSON in the shape of the schema; no tool ever runs. Keys come from the login keychain for
/// each request and go only to their vendor.
public enum ProviderAPI {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Room for the longest answer Reprise asks for, a meeting summary. Anthropic requires a limit.
    static let outputTokens = 8_192
    private static let cache = Cache()

    struct Reply {
        let payload: [String: Any]
        let model: String?
        let inputTokens: Int?
        let outputTokens: Int?
    }

    static func generate(input: Data, schema: String, systemPrompt: String, configuration: AIProviderConfiguration) async throws -> AIJSONResult {
        guard let vendor = configuration.provider.apiKeyProvider else { throw AIProviderError.unavailable }
        guard let key = APIKeys.load(vendor) else { throw AIProviderError.apiKeyMissing }
        let model = configuration.model.isEmpty ? try await automaticModel(configuration.provider, key: key) : configuration.model
        guard let format = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else { throw AIProviderError.invalidInput }
        let text = String(decoding: input, as: UTF8.self)
        let timeout = min(180, max(5, configuration.timeoutSeconds))
        let start = Date()
        let reply: Reply
        switch configuration.provider {
        case .openAIAPI:
            reply = try openAIReply(try await send(openAIRequest(key: key, model: model, instructions: systemPrompt, input: text,
                                                                 schema: format, timeout: timeout), vendor: vendor))
        case .anthropicAPI:
            reply = try anthropicReply(try await send(anthropicRequest(key: key, model: model, system: systemPrompt, input: text,
                                                                       schema: format, timeout: timeout), vendor: vendor))
        case .geminiAPI:
            let cleaned = (try? JSONSerialization.jsonObject(with: Data(AICommand.geminiSchema(schema).utf8))) as? [String: Any] ?? format
            do {
                reply = try geminiReply(try await send(geminiRequest(key: key, model: model, system: systemPrompt, input: text,
                                                                     schema: cleaned, timeout: timeout), vendor: vendor))
            } catch AIProviderError.apiFailed(let message) where message.lowercased().contains("schema") {
                // A model that takes no JSON schema still answers in JSON; the instructions name the keys.
                reply = try geminiReply(try await send(geminiRequest(key: key, model: model, system: systemPrompt, input: text,
                                                                     schema: nil, timeout: timeout), vendor: vendor))
            }
        default:
            throw AIProviderError.unavailable
        }
        let usage = UsageEntry(provider: configuration.provider.rawValue, model: reply.model ?? model, inputTokens: reply.inputTokens,
                               outputTokens: reply.outputTokens, durationSeconds: Date().timeIntervalSince(start))
        let window = await cache.window(configuration.provider, model)
        return AIJSONResult(payload: reply.payload, usage: usage, context: reply.inputTokens.map { AIContextUse(tokens: $0, window: window) })
    }

    // MARK: Requests

    /// OpenAI's Responses API. Nothing is stored on OpenAI's side for later retrieval.
    static func openAIRequest(key: String, model: String, instructions: String, input: String, schema: [String: Any], timeout: Double) throws -> URLRequest {
        var request = post("https://api.openai.com/v1/responses", timeout: timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": instructions, "input": input, "store": false,
            "text": ["format": ["type": "json_schema", "name": "reprise_answer", "schema": schema, "strict": false]]
        ] as [String: Any])
        return request
    }

    /// Anthropic's Messages API. The answer arrives as the input of a tool the model must call,
    /// which only carries the structure; Reprise runs nothing.
    static func anthropicRequest(key: String, model: String, system: String, input: String, schema: [String: Any], timeout: Double) throws -> URLRequest {
        var request = post("https://api.anthropic.com/v1/messages", timeout: timeout)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": outputTokens,
            "system": system + "\nGive the result as the input of the answer tool, which only records it.",
            "messages": [["role": "user", "content": input]],
            "tools": [["name": "answer", "description": "Records the answer in the required structure.", "input_schema": schema]],
            "tool_choice": ["type": "tool", "name": "answer"]
        ] as [String: Any])
        return request
    }

    /// Gemini's generateContent with a JSON response, shaped by the schema when one is given.
    static func geminiRequest(key: String, model: String, system: String, input: String, schema: [String: Any]?, timeout: Double) throws -> URLRequest {
        let id = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else { throw AIProviderError.invalidInput }
        var request = post("https://generativelanguage.googleapis.com/v1beta/models/\(id):generateContent", timeout: timeout)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        var generation: [String: Any] = ["responseMimeType": "application/json"]
        if let schema { generation["responseJsonSchema"] = schema }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": input]]]],
            "generationConfig": generation
        ] as [String: Any])
        return request
    }

    private static func post(_ address: String, timeout: Double) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: Replies

    static func openAIReply(_ object: [String: Any]) throws -> Reply {
        if let status = object["status"] as? String, status != "completed" {
            let reason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
            throw reason == "content_filter" ? AIProviderError.refused : AIProviderError.invalidResponse
        }
        var text = ""
        for item in object["output"] as? [[String: Any]] ?? [] {
            let type = item["type"] as? String ?? ""
            if type.hasSuffix("_call") { throw AIProviderError.toolAttempt }
            guard type == "message" else { continue }
            for part in item["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "refusal" { throw AIProviderError.refused }
                if part["type"] as? String == "output_text", let value = part["text"] as? String { text += value }
            }
        }
        guard let payload = AIResponseParser.jsonObject(in: text) else { throw AIProviderError.invalidResponse }
        let usage = object["usage"] as? [String: Any]
        return Reply(payload: payload, model: object["model"] as? String,
                     inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)
    }

    static func anthropicReply(_ object: [String: Any]) throws -> Reply {
        switch object["stop_reason"] as? String {
        case "max_tokens": throw AIProviderError.invalidResponse
        case "refusal": throw AIProviderError.refused
        default: break
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        guard let block = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "answer" }),
              let payload = block["input"] as? [String: Any] else { throw AIProviderError.invalidResponse }
        let usage = object["usage"] as? [String: Any]
        // Cached parts of the prompt are counted apart from the rest.
        let read = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage?[$0] as? Int }
        return Reply(payload: payload, model: object["model"] as? String,
                     inputTokens: read.isEmpty ? nil : read.reduce(0, +), outputTokens: usage?["output_tokens"] as? Int)
    }

    static func geminiReply(_ object: [String: Any]) throws -> Reply {
        if (object["promptFeedback"] as? [String: Any])?["blockReason"] != nil { throw AIProviderError.refused }
        guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { throw AIProviderError.invalidResponse }
        switch candidate["finishReason"] as? String ?? "STOP" {
        case "STOP": break
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": throw AIProviderError.refused
        default: throw AIProviderError.invalidResponse
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        if parts.contains(where: { $0["functionCall"] != nil }) { throw AIProviderError.toolAttempt }
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        guard let payload = AIResponseParser.jsonObject(in: text) else { throw AIProviderError.invalidResponse }
        let usage = object["usageMetadata"] as? [String: Any]
        // Thinking counts as output, as Google bills it.
        let output = ["candidatesTokenCount", "thoughtsTokenCount"].compactMap { usage?[$0] as? Int }
        return Reply(payload: payload, model: object["modelVersion"] as? String,
                     inputTokens: usage?["promptTokenCount"] as? Int, outputTokens: output.isEmpty ? nil : output.reduce(0, +))
    }

    // MARK: Sending

    static func send(_ request: URLRequest, vendor: APIKeyProvider) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw AIProviderError.cancelled
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch {
            throw AIProviderError.apiFailed("\(vendor.displayName) could not be reached: \(error.localizedDescription)")
        }
        guard data.count <= 8 * 1024 * 1024 else { throw AIProviderError.outputLimit }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else { throw failure(status: status, object: object, vendor: vendor) }
        guard let object else { throw AIProviderError.invalidResponse }
        return object
    }

    /// What went wrong, in the vendor's words where they help. A rejected key is never quoted,
    /// because vendors echo part of it.
    static func failure(status: Int, object: [String: Any]?, vendor: APIKeyProvider) -> AIProviderError {
        let error = object?["error"] as? [String: Any]
        let message = (error?["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        let code = [error?["code"], error?["type"], error?["status"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
        let keyRejected = status == 401 || code.contains("authentication") || code.contains("invalid_api_key")
            || lower.contains("api key") && (lower.contains("invalid") || lower.contains("not valid") || lower.contains("incorrect") || lower.contains("expired"))
        if keyRejected { return .apiFailed("\(vendor.displayName) did not accept the API key. Check it in AI & Models.") }
        let tooLong = status != 429 && (status == 413 || code.contains("context_length") || lower.contains("context window") || lower.contains("context length")
            || lower.contains("prompt is too long") || lower.contains("token") && lower.contains("exceed"))
        if tooLong { return .contextTooLarge }
        let shown = message.isEmpty ? "HTTP \(status)" : String(message.prefix(300))
        switch status {
        case 404: return .apiFailed("\(vendor.displayName) cannot use this model: \(shown) Choose another model in AI & Models.")
        case 429: return .apiFailed("\(vendor.displayName) limit reached: \(shown)")
        default: return .apiFailed("\(vendor.displayName): \(shown)")
        }
    }

    // MARK: Models

    /// The models the key can use, newest first. This never sends a prompt.
    public static func models(_ kind: AIProviderKind) async -> [AIModelOption] {
        guard let vendor = kind.apiKeyProvider, let key = APIKeys.load(vendor) else { return [] }
        return (try? await listModels(kind, key: key)) ?? []
    }

    /// Lists models, which also shows whether the key works.
    static func listModels(_ kind: AIProviderKind, key: String) async throws -> [AIModelOption] {
        switch kind {
        case .openAIAPI:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 15)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return openAIModels(try await send(request, vendor: .openAI))
        case .anthropicAPI:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!, timeoutInterval: 15)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let object = try await send(request, vendor: .anthropic)
            for row in object["data"] as? [[String: Any]] ?? [] {
                if let id = row["id"] as? String, let window = row["max_input_tokens"] as? Int { await cache.setWindow(kind, id, window) }
            }
            return anthropicModels(object)
        case .geminiAPI:
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!, timeoutInterval: 15)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let object = try await send(request, vendor: .gemini)
            for row in object["models"] as? [[String: Any]] ?? [] {
                if let name = row["name"] as? String, let window = row["inputTokenLimit"] as? Int {
                    await cache.setWindow(kind, String(name.dropFirst("models/".count)), window)
                }
            }
            return geminiModels(object)
        default:
            return []
        }
    }

    /// Text models that answer through the Responses API, without dated snapshots, newest first.
    static func openAIModels(_ object: [String: Any]) -> [AIModelOption] {
        let other = ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "moderation", "instruct",
                     "computer-use", "deep-research", "diarize"]
        let rows = (object["data"] as? [[String: Any]] ?? []).compactMap { row -> (id: String, created: Int)? in
            guard let id = row["id"] as? String, AICommand.validModel(id),
                  id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-") || id.first == "o" && id.dropFirst().first?.isNumber == true,
                  !other.contains(where: id.contains), id.range(of: #"-\d{4}(-\d{2}-\d{2})?$"#, options: .regularExpression) == nil
            else { return nil }
            return (id, row["created"] as? Int ?? 0)
        }
        return rows.sorted { ($0.created, $0.id) > ($1.created, $1.id) }.map { AIModelOption(id: $0.id, name: $0.id) }
    }

    /// Anthropic lists its models newest first.
    static func anthropicModels(_ object: [String: Any]) -> [AIModelOption] {
        (object["data"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, AICommand.validModel(id) else { return nil }
            return AIModelOption(id: id, name: row["display_name"] as? String ?? id)
        }
    }

    /// Gemini and Gemma models that write text, highest version first.
    static func geminiModels(_ object: [String: Any]) -> [AIModelOption] {
        let other = ["embedding", "image", "tts", "live", "aqa", "audio", "robotics", "computer-use", "learnlm", "veo", "imagen"]
        let rows = (object["models"] as? [[String: Any]] ?? []).compactMap { row -> AIModelOption? in
            guard let name = row["name"] as? String, name.hasPrefix("models/"),
                  (row["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { return nil }
            let id = String(name.dropFirst("models/".count))
            guard id.hasPrefix("gemini-") || id.hasPrefix("gemma-"), AICommand.validModel(id), !other.contains(where: id.contains) else { return nil }
            return AIModelOption(id: id, name: row["displayName"] as? String ?? id)
        }
        return rows.sorted { (version($0.id), $1.id) > (version($1.id), $0.id) }
    }

    /// "gemini-3.5-flash" is 3.5; names without a number sort last.
    static func version(_ id: String) -> Double {
        guard let range = id.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return 0 }
        return Double(id[range]) ?? 0
    }

    /// The model used when none is chosen: each vendor's fast, low-cost model, from what the key lists.
    public static func automaticModel(_ kind: AIProviderKind, from ids: [String]) -> String? {
        func stable(_ id: String) -> Bool { !id.contains("preview") && !id.contains("exp") }
        switch kind {
        case .openAIAPI:
            return ids.first { $0.range(of: #"^gpt-\d+(\.\d+)?-mini$"#, options: .regularExpression) != nil }
                ?? ids.first { $0.range(of: #"^gpt-\d+(\.\d+)?$"#, options: .regularExpression) != nil } ?? ids.first
        case .anthropicAPI:
            return ids.first { $0.contains("haiku") } ?? ids.first { $0.contains("sonnet") } ?? ids.first
        case .geminiAPI:
            let flash = ids.filter { $0.hasPrefix("gemini-") && $0.contains("flash") && !$0.contains("lite") }
            guard let top = flash.first.map(version) else { return ids.first { $0.hasPrefix("gemini-") } ?? ids.first }
            let newest = flash.filter { version($0) == top }
            return newest.first(where: stable) ?? newest.first
        default:
            return nil
        }
    }

    static func automaticModel(_ kind: AIProviderKind, key: String) async throws -> String {
        // Swift seeds string hashes per launch, so this slot never outlives the process.
        let slot = "\(kind.rawValue)-\(key.hashValue)"
        if let chosen = await cache.model(slot) { return chosen }
        let ids = try await listModels(kind, key: key).map(\.id)
        guard let chosen = automaticModel(kind, from: ids) else {
            throw AIProviderError.apiFailed("\(kind.apiKeyProvider?.displayName ?? kind.displayName) lists no model this key can use.")
        }
        await cache.setModel(slot, chosen)
        return chosen
    }

    private actor Cache {
        private var models: [String: String] = [:]
        private var windows: [String: Int] = [:]
        func model(_ slot: String) -> String? { models[slot] }
        func setModel(_ slot: String, _ model: String) { models[slot] = model }
        func window(_ kind: AIProviderKind, _ model: String) -> Int? { windows["\(kind.rawValue)/\(model)"] }
        func setWindow(_ kind: AIProviderKind, _ model: String, _ tokens: Int) { windows["\(kind.rawValue)/\(model)"] = tokens }
    }
}
