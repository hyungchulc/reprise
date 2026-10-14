import XCTest
@testable import RepriseCore

final class QuickSearchTimeTests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        value.firstWeekday = 2
        return value
    }()
    /// Wednesday 14 October 2026, 15:30 in Stockholm.
    private var now: Date { day(10, 14, 15).addingTimeInterval(1_800) }
    private func day(_ month: Int, _ day: Int, _ hour: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func parse(_ text: String) -> QuickSearchTime? { QuickSearchTime.parse(text, now: now, calendar: calendar) }

    func testDayWordsShowThatLocalDay() {
        for text in ["오늘", "오늘꺼", "today", "Today"] {
            XCTAssertEqual(parse(text)?.interval, DateInterval(start: day(10, 14), end: day(10, 15)), text)
            XCTAssertEqual(parse(text)?.text, "", text)
        }
        let meeting = parse("어제 회의")
        XCTAssertEqual(meeting?.interval, DateInterval(start: day(10, 13), end: day(10, 14)))
        XCTAssertEqual(meeting?.label, "Yesterday")
        XCTAssertEqual(meeting?.text, "회의")
        XCTAssertEqual(parse("3일 전")?.interval.start, day(10, 11))
        XCTAssertEqual(parse("10월 13일")?.interval.start, day(10, 13))
        XCTAssertEqual(parse("12/25")?.interval.start, day(12, 25, year: 2025))
        XCTAssertEqual(parse("월요일에 본 문서")?.interval.start, day(10, 12))
        XCTAssertEqual(parse("월요일에 본 문서")?.text, "본 문서")
    }

    func testWeeksMonthsAndPartsOfTheDay() {
        XCTAssertEqual(parse("지난주")?.interval, DateInterval(start: day(10, 5), end: day(10, 12)))
        XCTAssertEqual(parse("this month")?.interval.start, day(10, 1))
        let evening = parse("어제 저녁")
        XCTAssertEqual(evening?.interval, DateInterval(start: day(10, 13, 17), end: day(10, 13, 22)))
        XCTAssertEqual(evening?.label, "Yesterday evening")
        XCTAssertEqual(parse("어젯밤")?.interval.end, day(10, 14, 4))
    }

    func testEverydayWordsStayTextSearches() {
        for text in ["회의", "budget forecast", "점심 메뉴", "good morning", "13일", ""] { XCTAssertNil(parse(text), text) }
    }

    func testModelFamiliesGroupThinkingLevels() {
        let options = [("gpt-5.3-codex", "GPT-5.3 Codex"), ("gpt-5.3-codex-high", "GPT-5.3 Codex High"),
                       ("gpt-5.3-codex-low-fast", "GPT-5.3 Codex Low Fast"), ("gpt-5.3-codex-fast", "GPT-5.3 Codex Fast"),
                       ("gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"), ("gemini-3.8-flash-low", "Gemini 3.8 Flash (Low)"),
                       ("claude-opus-5.5-xhigh", "Claude Opus 5.5 Extra High"), ("sonnet", "Sonnet")]
            .map { AIModelOption(id: $0.0, name: $0.1) }
        let families = AIModelFamily.families(options)
        XCTAssertEqual(families.map(\.id), ["gpt-5.3-codex", "gpt-5.3-codex-fast", "gemini-3.8-flash", "claude-opus-5.5", "sonnet"])
        XCTAssertEqual(families.map(\.name), ["GPT-5.3 Codex", "GPT-5.3 Codex Fast", "Gemini 3.8 Flash", "Claude Opus 5.5", "Sonnet"])
        XCTAssertEqual(families[0].levels.map(\.level), ["", "high"])
        XCTAssertEqual(families[2].levels.map(\.level), ["low", "high"])
        XCTAssertEqual(families[2].model(keeping: "high"), "gemini-3.8-flash-high")
        XCTAssertEqual(families[2].model(keeping: "xhigh"), "gemini-3.8-flash-low")
        XCTAssertEqual(AIModelFamily.geminiDefault(options), "gemini-3.8-flash-low")
    }

    func testThinkingLevelReachesEachProvider() {
        func value(after flag: String, _ configuration: AIProviderConfiguration) -> String? {
            let args = AICommand.arguments(configuration: configuration)
            return args.firstIndex(of: flag).map { args[$0 + 1] }
        }
        XCTAssertEqual(value(after: "--effort", AIProviderConfiguration()), "high")
        XCTAssertEqual(value(after: "--effort", AIProviderConfiguration(reasoningEffort: "max")), "max")
        XCTAssertEqual(value(after: "--effort", AIProviderConfiguration(reasoningEffort: "invented")), "high")
        XCTAssertEqual(value(after: "--reasoning-effort", AIProviderConfiguration(provider: .grok, reasoningEffort: "low")), "low")
        XCTAssertTrue(AICommand.arguments(configuration: AIProviderConfiguration(provider: .codex)).contains { $0.hasPrefix("model_reasoning_effort=") })
    }

    func testFastTwinsAreFoundByName() {
        let grok = ["grok-4.6", "grok-4.5", "grok-4.7", "grok-4.7-build-fast"]
        XCTAssertEqual(AIModelFamily.speedCounterpart(of: "grok-4.7", fast: true, in: grok), "grok-4.7-build-fast")
        XCTAssertEqual(AIModelFamily.speedCounterpart(of: "grok-4.7-build-fast", fast: false, in: grok), "grok-4.7")
        XCTAssertNil(AIModelFamily.speedCounterpart(of: "grok-4.6", fast: true, in: grok))
        let cursor = ["grok-4.7", "grok-4.7-fast", "composer-2.5", "composer-2.5-fast", "cursor-grok-4.5-fast"]
        XCTAssertEqual(AIModelFamily.speedCounterpart(of: "composer-2.5", fast: true, in: cursor), "composer-2.5-fast")
        XCTAssertEqual(AIModelFamily.speedCounterpart(of: "grok-4.7-fast", fast: false, in: cursor), "grok-4.7")
        XCTAssertNil(AIModelFamily.speedCounterpart(of: "cursor-grok-4.5-fast", fast: false, in: cursor))
        let listed = AIClient.grokModels("Available models:\n  - grok-4.7\n  * grok-4.7-build-fast (default)\n")
        XCTAssertEqual(listed.map(\.isDefault), [false, true])
    }

    func testFastModeReachesClaudeOnlyOnOpus() {
        func settings(_ configuration: AIProviderConfiguration) -> String? {
            let args = AICommand.arguments(configuration: configuration)
            return args.firstIndex(of: "--settings").map { args[$0 + 1] }
        }
        XCTAssertEqual(settings(AIProviderConfiguration(model: "opus", fast: true)), #"{"disableAllHooks":true,"fastMode":true}"#)
        XCTAssertEqual(settings(AIProviderConfiguration(model: "sonnet", fast: true)), #"{"disableAllHooks":true}"#)
        XCTAssertEqual(settings(AIProviderConfiguration(model: "opus")), #"{"disableAllHooks":true}"#)
    }

    func testCodexFastTierAndWindowComeFromItsCatalog() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let catalog = #"{"models":[{"slug":"sol","visibility":"list","priority":1,"context_window":500000,"service_tiers":[{"id":"priority","name":"Fast","description":"2x speed, increased usage"}]},{"slug":"plain","visibility":"list","priority":2,"context_window":272000,"service_tiers":[]}]}"#
        try Data(catalog.utf8).write(to: home.appendingPathComponent(".codex/models_cache.json"))
        XCTAssertEqual(CodexAnswerCatalog.fastTier(model: "sol", home: home)?.id, "priority")
        XCTAssertEqual(CodexAnswerCatalog.fastTier(model: "sol", home: home)?.note, "2x speed, increased usage")
        XCTAssertNil(CodexAnswerCatalog.fastTier(model: "plain", home: home))
        XCTAssertEqual(CodexAnswerCatalog.contextWindow(model: "plain", home: home), 272000)
    }

    func testClaudeContextCountsCachedTokens() throws {
        let data = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"{\"answer\":\"ok\"}","structured_output":{"answer":"ok"},"usage":{"input_tokens":12,"cache_creation_input_tokens":3000,"cache_read_input_tokens":17000,"output_tokens":40},"modelUsage":{"claude-opus-5-5":{"contextWindow":1000000}}}"#.utf8)
        let parsed = try AIResponseParser.structured(data, provider: .claude, requestedModel: "opus", duration: 1)
        XCTAssertEqual(parsed.context, AIContextUse(tokens: 20012, window: 1_000_000))
        XCTAssertEqual(parsed.context?.fraction ?? 0, 0.020012, accuracy: 0.000001)
    }

    func testWideScriptsLeadTextRecognition() {
        XCTAssertEqual(ScreenTextLanguages.hints(["en-US", "ko-KR"]), ["ko-KR", "en-US"])
        XCTAssertEqual(ScreenTextLanguages.hints(["sv-SE", "en-US"]), ["sv-SE", "en-US"])
    }

    func testRecognizedTextReplacesTheOldTextInSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-reread-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        try await store.insert(Moment(id: "screen", timestamp: Date(timeIntervalSince1970: 100), appName: "Fixture", text: "QEOE E"))
        let pending = try await store.screensNeedingTextCount()
        XCTAssertEqual(pending, 0)
        try await store.saveRecognizedText(id: "screen", text: "오늘 회의 예산")
        let found = try await store.search(MomentQuery(text: "예산"))
        XCTAssertEqual(found.map(\.id), ["screen"])
        let old = try await store.search(MomentQuery(text: "QEOE"))
        XCTAssertTrue(old.isEmpty)
    }
}
