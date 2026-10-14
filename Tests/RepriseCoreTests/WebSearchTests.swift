import XCTest
@testable import RepriseCore

/// Web lookups for the meeting assistant: which route Automatic takes, what each CLI may do, and how answers are read.
final class WebSearchTests: XCTestCase {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testCLIsMaySearchTheWebAndNothingElse() {
        let codex = WebSearch.arguments(.codex, configuration: AIProviderConfiguration(provider: .codex, reasoningEffort: "low"))
        XCTAssertTrue(codex.contains(#"web_search="live""#))
        XCTAssertFalse(codex.contains(#"web_search="disabled""#))
        XCTAssertTrue(codex.contains(#"sandbox"#) || codex.contains("--sandbox"))
        let claude = WebSearch.arguments(.claude, configuration: AIProviderConfiguration(provider: .claude, reasoningEffort: "low"))
        let tools = claude.firstIndex(of: "--tools").map { claude[$0 + 1] }
        XCTAssertEqual(tools, "WebSearch")
        XCTAssertEqual(claude.suffix(2), ["--allowedTools", "WebSearch"])
        XCTAssertFalse(claude.contains("WebFetch"))
    }

    func testAutomaticPrefersWhatThePersonAlreadyPaysWith() {
        let missing = AIProviderConfiguration(provider: .codex, executablePath: "/nonexistent/codex")
        let none = WebSearch.Tools(codex: missing, claude: AIProviderConfiguration(provider: .claude, executablePath: "/nonexistent/claude"))
        if !APIKeys.has(.openAI) && !APIKeys.has(.gemini) && !APIKeys.has(.anthropic) {
            XCTAssertNil(WebSearch.resolve(.automatic, none))
        }
        let shell = AIProviderConfiguration(provider: .claude, executablePath: "/bin/sh")
        XCTAssertEqual(WebSearch.resolve(.automatic, WebSearch.Tools(codex: missing, claude: shell)), .claude)
        XCTAssertEqual(WebSearch.resolve(.automatic, WebSearch.Tools(codex: AIProviderConfiguration(provider: .codex, executablePath: "/bin/sh"), claude: shell)), .codex)
        XCTAssertNil(WebSearch.resolve(.codex, none))
    }

    func testCLIAnswersAreReadAndOtherToolsRejected() throws {
        let codex = """
        {"type":"thread.started"}
        {"type":"item.completed","item":{"type":"web_search","query":"swift 7 release"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"{\\"answer\\":\\"Swift 7 shipped in September.\\",\\"sources\\":[{\\"title\\":\\"Swift.org\\",\\"url\\":\\"https://swift.org/blog\\"},{\\"title\\":\\"dup\\",\\"url\\":\\"https://swift.org/blog\\"},{\\"title\\":\\"bad\\",\\"url\\":\\"file:///etc\\"}]}"}}
        {"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
        """
        let read = try WebSearch.cliResult(Data(codex.utf8), kind: .codex)
        XCTAssertEqual(read.text, "Swift 7 shipped in September.")
        XCTAssertEqual(read.sources.map(\.url), ["https://swift.org/blog"])
        let acted = #"{"type":"item.completed","item":{"type":"command_execution","command":"ls"}}"#
        XCTAssertThrowsError(try WebSearch.cliResult(Data(acted.utf8), kind: .codex)) { XCTAssertEqual($0 as? AIProviderError, .toolAttempt) }

        let claude = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"answer":"Yes.","sources":[{"title":"A","url":"https://a.example"}]}}"#
        XCTAssertEqual(try WebSearch.cliResult(Data(claude.utf8), kind: .claude).sources.first?.title, "A")
        XCTAssertThrowsError(try WebSearch.cliResult(Data(#"{"type":"result","subtype":"error_max_turns"}"#.utf8), kind: .claude))
    }

    func testAPIAnswersCarryTheirPages() throws {
        let openAI = try WebSearch.apiResult(.openAIAPI, object("""
        {"output":[{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"It is 12°C.","annotations":[{"type":"url_citation","url":"https://weather.example","title":"Weather"}]}]}]}
        """))
        XCTAssertEqual(openAI.sources, [.init(title: "Weather", url: "https://weather.example")])
        let anthropic = try WebSearch.apiResult(.anthropicAPI, object("""
        {"content":[{"type":"server_tool_use","name":"web_search"},{"type":"web_search_tool_result","content":[]},{"type":"text","text":"It is 12°C.","citations":[{"type":"web_search_result_location","url":"https://weather.example","title":"Weather"}]}]}
        """))
        XCTAssertEqual(anthropic.text, "It is 12°C.")
        XCTAssertEqual(anthropic.sources.count, 1)
        let gemini = try WebSearch.apiResult(.geminiAPI, object("""
        {"candidates":[{"content":{"parts":[{"text":"It is 12°C."}]},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://vertexaisearch.example/r","title":"weather.example"}}]}}]}
        """))
        XCTAssertEqual(gemini.sources.first?.title, "weather.example")
        let request = try WebSearch.apiRequest(.geminiAPI, key: "k", model: "gemini-x-flash", query: "q", timeout: 30)
        XCTAssertFalse(request.url?.absoluteString.contains("k&") ?? true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "k")
    }

    /// Searches the web through the CLIs installed here, with their own sign-ins.
    func testCLIsSearchTheWebWhenRequested() async throws {
        guard let wanted = ProcessInfo.processInfo.environment["REPRISE_TEST_WEB"] else { throw XCTSkip("Set REPRISE_TEST_WEB=codex,claude to search the web.") }
        for name in wanted.split(separator: ",").map(String.init) {
            guard let route = WebSearchRoute(rawValue: name), route == .codex || route == .claude else { continue }
            let start = Date()
            let result = try await WebSearch.search("What is the latest stable version of the Swift programming language?", route: route, tools: WebSearch.Tools(), timeout: 120)
            print("\(route.rawValue) web search in \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(result.text) \(result.sources.map(\.url))")
            XCTAssertFalse(result.text.isEmpty)
        }
    }
}
