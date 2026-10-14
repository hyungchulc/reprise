import XCTest
@testable import RepriseCore

/// The API-key providers: what each request carries, how each reply is read, and which model is used.
final class ProviderAPITests: XCTestCase {
    private let schema: [String: Any] = try! JSONSerialization.jsonObject(with: Data(AIEvidenceInput.responseSchema.utf8)) as! [String: Any]

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testRequestsCarryTheKeyOnlyInTheVendorsHeader() throws {
        let openAI = try ProviderAPI.openAIRequest(key: "test-key", model: "gpt-x-mini", instructions: "Rules", input: "{}", schema: schema, timeout: 30)
        XCTAssertEqual(openAI.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let sent = try body(openAI)
        XCTAssertEqual(sent["store"] as? Bool, false)
        XCTAssertEqual(sent["instructions"] as? String, "Rules")
        XCTAssertEqual(((sent["text"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String, "json_schema")

        let anthropic = try ProviderAPI.anthropicRequest(key: "test-key", model: "claude-x", system: "Rules", input: "{}", schema: schema, timeout: 30)
        XCTAssertEqual(anthropic.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let message = try body(anthropic)
        XCTAssertEqual((message["tool_choice"] as? [String: Any])?["name"] as? String, "answer")
        XCTAssertNotNil(message["max_tokens"] as? Int)

        let gemini = try ProviderAPI.geminiRequest(key: "test-key", model: "models/gemini-x-flash", system: "Rules", input: "{}", schema: schema, timeout: 30)
        XCTAssertEqual(gemini.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-x-flash:generateContent")
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertFalse(gemini.url?.absoluteString.contains("test-key") ?? true)
        XCTAssertNotNil((try body(gemini)["generationConfig"] as? [String: Any])?["responseJsonSchema"])
        XCTAssertNil((try body(ProviderAPI.geminiRequest(key: "k", model: "gemini-x", system: "", input: "", schema: nil, timeout: 30))["generationConfig"] as? [String: Any])?["responseJsonSchema"])
        // A model name never reaches the path as anything but a name.
        XCTAssertThrowsError(try ProviderAPI.geminiRequest(key: "k", model: "x/../y?key=1", system: "", input: "", schema: nil, timeout: 30))
    }

    func testRepliesYieldTheJSONAndUsage() throws {
        let openAI = try ProviderAPI.openAIReply(object("""
        {"status":"completed","model":"gpt-x-mini","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"{\\"answer\\":\\"Yes [M1]\\",\\"citations\\":[\\"M1\\"]}"}]}],"usage":{"input_tokens":120,"output_tokens":30}}
        """))
        XCTAssertEqual(openAI.payload["answer"] as? String, "Yes [M1]")
        XCTAssertEqual(openAI.inputTokens, 120)
        XCTAssertThrowsError(try ProviderAPI.openAIReply(object(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#)))
        XCTAssertThrowsError(try ProviderAPI.openAIReply(object(#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}"#))) {
            XCTAssertEqual($0 as? AIProviderError, .refused)
        }
        XCTAssertThrowsError(try ProviderAPI.openAIReply(object(#"{"status":"completed","output":[{"type":"function_call","name":"x"}]}"#))) {
            XCTAssertEqual($0 as? AIProviderError, .toolAttempt)
        }

        let anthropic = try ProviderAPI.anthropicReply(object("""
        {"model":"claude-x","stop_reason":"tool_use","content":[{"type":"text","text":"Here"},{"type":"tool_use","name":"answer","input":{"answer":"Yes","citations":[]}}],"usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":9}}
        """))
        XCTAssertEqual(anthropic.payload["answer"] as? String, "Yes")
        XCTAssertEqual(anthropic.inputTokens, 120)
        XCTAssertThrowsError(try ProviderAPI.anthropicReply(object(#"{"stop_reason":"max_tokens","content":[]}"#)))

        let gemini = try ProviderAPI.geminiReply(object("""
        {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"thinking","thought":true},{"text":"{\\"answer\\":\\"Yes\\",\\"citations\\":[]}"}]}}],"usageMetadata":{"promptTokenCount":80,"candidatesTokenCount":10,"thoughtsTokenCount":5},"modelVersion":"gemini-x"}
        """))
        XCTAssertEqual(gemini.payload["answer"] as? String, "Yes")
        XCTAssertEqual(gemini.outputTokens, 15)
        XCTAssertThrowsError(try ProviderAPI.geminiReply(object(#"{"candidates":[{"finishReason":"SAFETY"}]}"#))) {
            XCTAssertEqual($0 as? AIProviderError, .refused)
        }
    }

    func testFailuresExplainWithoutRepeatingTheKey() {
        let rejected = ProviderAPI.failure(status: 401, object: object(#"{"error":{"message":"Incorrect API key provided: sk-abc***xyz.","code":"invalid_api_key"}}"#), vendor: .openAI)
        XCTAssertFalse(rejected.localizedDescription.contains("sk-"))
        XCTAssertTrue(rejected.localizedDescription.contains("did not accept the API key"))
        let gemini = ProviderAPI.failure(status: 400, object: object(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#), vendor: .gemini)
        XCTAssertTrue(gemini.localizedDescription.contains("did not accept the API key"))
        // Too much evidence is retried with less; a rate limit that mentions tokens is not.
        XCTAssertEqual(ProviderAPI.failure(status: 400, object: object(#"{"error":{"message":"prompt is too long: 250000 tokens > 200000 maximum"}}"#), vendor: .anthropic), .contextTooLarge)
        XCTAssertEqual(ProviderAPI.failure(status: 400, object: object(#"{"error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model."}}"#), vendor: .openAI), .contextTooLarge)
        let limited = ProviderAPI.failure(status: 429, object: object(#"{"error":{"message":"This request would exceed the rate limit of 50,000 input tokens per minute."}}"#), vendor: .anthropic)
        XCTAssertNotEqual(limited, .contextTooLarge)
        XCTAssertTrue(limited.localizedDescription.hasPrefix("Anthropic limit reached"))
        XCTAssertTrue(ProviderAPI.failure(status: 404, object: object(#"{"error":{"message":"The model `x` does not exist."}}"#), vendor: .openAI)
            .localizedDescription.contains("Choose another model"))
    }

    func testModelListsAndTheAutomaticChoice() {
        let openAI = ProviderAPI.openAIModels(object("""
        {"data":[{"id":"gpt-9","created":30},{"id":"gpt-9-mini","created":31},{"id":"gpt-9-mini-2031-01-01","created":32},{"id":"gpt-9-realtime","created":33},
                 {"id":"text-embedding-9","created":34},{"id":"o9","created":20},{"id":"gpt-8-mini","created":10},{"id":"gpt-image-9","created":35}]}
        """)).map(\.id)
        XCTAssertEqual(openAI, ["gpt-9-mini", "gpt-9", "o9", "gpt-8-mini"])
        XCTAssertEqual(ProviderAPI.automaticModel(.openAIAPI, from: openAI), "gpt-9-mini")

        let anthropic = ProviderAPI.anthropicModels(object("""
        {"data":[{"id":"claude-opus-9","display_name":"Claude Opus 9"},{"id":"claude-sonnet-9","display_name":"Claude Sonnet 9"},{"id":"claude-haiku-9","display_name":"Claude Haiku 9"},{"id":"claude-haiku-8"}]}
        """)).map(\.id)
        XCTAssertEqual(ProviderAPI.automaticModel(.anthropicAPI, from: anthropic), "claude-haiku-9")

        let gemini = ProviderAPI.geminiModels(object("""
        {"models":[{"name":"models/gemini-8-flash","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-9-flash-preview","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-9-flash","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-9-flash-lite","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-9-pro","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-9-flash-image","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-embedding-9","supportedGenerationMethods":["embedContent"]}]}
        """)).map(\.id)
        XCTAssertFalse(gemini.contains("gemini-9-flash-image"))
        XCTAssertEqual(ProviderAPI.automaticModel(.geminiAPI, from: gemini), "gemini-9-flash")
    }

    func testProvidersWithoutAKeyAreNotReady() async {
        guard !APIKeys.has(.anthropic) else { return }
        let status = await AIClient().status(configuration: AIProviderConfiguration(provider: .anthropicAPI))
        XCTAssertFalse(status.canAnswer)
        XCTAssertNil(AIProviderKind.anthropicAPI.commandName)
        XCTAssertNil(AIProviderKind.anthropicAPI.installScript)
    }

    /// Reaches each vendor with a made-up key, which proves the address and the key header
    /// without an account: every vendor must refuse the key, not the request.
    func testVendorsRefuseAMadeUpKeyWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_API_ENDPOINTS"] == "1" else { throw XCTSkip("Set REPRISE_TEST_API_ENDPOINTS=1 to reach the vendors.") }
        let fake = "reprise-test-not-a-key"
        let requests: [(APIKeyProvider, URLRequest)] = [
            (.openAI, try ProviderAPI.openAIRequest(key: fake, model: "gpt-5-mini", instructions: "Answer.", input: "{}", schema: schema, timeout: 20)),
            (.anthropic, try ProviderAPI.anthropicRequest(key: fake, model: "claude-haiku-4-5", system: "Answer.", input: "{}", schema: schema, timeout: 20)),
            (.gemini, try ProviderAPI.geminiRequest(key: fake, model: "gemini-2.5-flash", system: "Answer.", input: "{}", schema: schema, timeout: 20))
        ]
        for (vendor, request) in requests {
            do {
                _ = try await ProviderAPI.send(request, vendor: vendor)
                XCTFail("\(vendor.displayName) accepted a made-up key")
            } catch {
                print("\(vendor.displayName): \(error.localizedDescription)")
                XCTAssertTrue(error.localizedDescription.contains("did not accept the API key"), "\(vendor.displayName): \(error.localizedDescription)")
            }
        }
        for kind in [AIProviderKind.openAIAPI, .anthropicAPI, .geminiAPI] {
            do {
                _ = try await ProviderAPI.listModels(kind, key: fake)
                XCTFail("\(kind.displayName) listed models for a made-up key")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("did not accept the API key"), "\(kind.displayName): \(error.localizedDescription)")
            }
        }
    }
}
