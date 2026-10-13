import XCTest
@testable import RepriseCore

final class SearchContinuityTests: XCTestCase {
    func testOverviewConversationRestoresEvidenceBeyondTwoHundredIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-history-overview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root)
        var turns: [MemorySearchTurn] = []
        for turn in 0..<3 {
            var citations: [AICitation] = []
            for index in 0..<96 {
                let id = "\(turn)-\(index)"
                try await store.insert(Moment(id: id, appName: "Fixture", text: "Original evidence"))
                citations.append(AICitation(momentID: id, label: "M\(index + 1)"))
            }
            turns.append(MemorySearchTurn(question: "Interval \(turn)", response: AIResponse(text: "Saved overview",
                citations: citations, usage: UsageEntry(provider: "fixture", model: "fixture"))))
        }
        let saved = SavedSearchResult(response: turns.last!.response, moments: [], turns: turns)
        let restored = try await saved.restore(from: store)
        XCTAssertEqual(restored.turns, turns)
        XCTAssertEqual(restored.missingCount, 0)
    }

    func testSavedAnswerSurvivesReopenWithoutNewSearchOrUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root)
        let first = Moment(id: "first", appName: "Meeting", text: "Original evidence", kind: "meeting")
        let second = Moment(id: "second", appName: "Meeting", text: "Second evidence", kind: "meeting")
        for moment in [first, second] { try await store.insert(moment) }
        let response = AIResponse(text: "Previously answered [1]", citations: [AICitation(momentID: first.id, label: "1")], usage: UsageEntry(provider: "claude", model: "saved-model", inputTokens: 12, outputTokens: 8))
        var history = SearchHistory()
        let turns = [MemorySearchTurn(question: "meeting notes", response: response), MemorySearchTurn(question: "what happened next?", response: response)]
        history.record("meeting notes", result: SavedSearchResult(response: response, moments: [second, first], appName: "Meeting", kind: "meeting", turns: turns))
        try history.save(root: root)
        let saved = try XCTUnwrap(SearchHistory.load(root: root).result(for: "MEETING notes"))
        let restored = try await saved.restore(from: store)
        XCTAssertEqual(restored.response, response)
        XCTAssertEqual(restored.turns, turns)
        XCTAssertEqual(restored.moments.map(\.id), ["second", "first"])
        XCTAssertEqual(saved.kind, "meeting")
        XCTAssertEqual(saved.appName, "Meeting")
        let usage = try await store.usage(since: nil)
        XCTAssertTrue(usage.isEmpty)
        try await store.delete(ids: [first.id])
        let afterDelete = try await saved.restore(from: store)
        XCTAssertEqual(afterDelete.moments.map(\.id), ["second"])
        XCTAssertTrue(afterDelete.response.citations.isEmpty)
        XCTAssertTrue(afterDelete.turns.allSatisfy { $0.response.citations.isEmpty })
        XCTAssertEqual(afterDelete.missingCount, 1)
        XCTAssertEqual(afterDelete.response.text, response.text)
    }

    func testLegacyHistoryAndEvictionDoNotInventAnswers() throws {
        var legacy = try JSONDecoder().decode(SearchHistory.self, from: Data(#"{"queries":["old","earlier"]}"#.utf8))
        XCTAssertEqual(legacy.queries, ["old", "earlier"])
        XCTAssertNil(legacy.result(for: "old"))
        let response = AIResponse(text: "Saved", citations: [], usage: UsageEntry(provider: "grok", model: "original"))
        legacy.record("new", result: SavedSearchResult(response: response, moments: []))
        legacy.record("NEW")
        XCTAssertEqual(legacy.result(for: "new")?.response.text, "Saved")
        for query in ["a", "b", "c"] { legacy.record(query) }
        XCTAssertNil(legacy.result(for: "new"))
        XCTAssertEqual(legacy.queries, ["c", "b", "a"])
    }

    func testRecentSearchesPersistPerVaultAndKeepThreeUniqueQueries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var history = SearchHistory()
        for query in ["first", "second", "third", "fourth", " SECOND ", "   "] { history.record(query) }
        try history.save(root: root)
        XCTAssertEqual(SearchHistory.load(root: root).queries, ["SECOND", "fourth", "third"])
        XCTAssertTrue(SearchHistory.load(root: root.appendingPathComponent("other-vault")).queries.isEmpty)
    }

    func testOldIndexedMemoriesSurviveReopenAndRankAboveRecentNoise() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-continuity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root)
        let old = Moment(id: "old", timestamp: Date(timeIntervalSince1970: 100.125), appName: "Fixture", windowTitle: "marigold", text: "marigold validation")
        try await store.insert(old)
        for index in 0..<240 {
            try await store.insert(Moment(id: "recent-\(index)", timestamp: Date(timeIntervalSince1970: 500 + Double(index * 3)), appName: "Fixture", text: "marigold " + String(repeating: "unrelated ", count: 40)))
        }
        let reopened = try MomentStore(root: root)
        let stats = try await reopened.stats()
        XCTAssertEqual(stats.momentCount, 241)
        XCTAssertEqual(stats.oldest, old.timestamp)
        let ranked = try await reopened.search(MomentQuery(text: "marigold", limit: 24))
        XCTAssertEqual(ranked.first?.id, old.id)
        let sample = try await reopened.sample(MomentQuery(limit: 12))
        XCTAssertTrue(sample.contains { $0.id == old.id })
        let filtered = try await reopened.search(MomentQuery(text: "marigold", since: Date(timeIntervalSince1970: 500), limit: 24))
        XCTAssertFalse(filtered.contains { $0.id == old.id })
        let plan = try MemorySearchPlan(payload: ["terms": ["marigold"], "since": NSNull(), "until": NSNull(), "kind": NSNull()], timeZone: .gmt)
        let results = try await MemorySearch(store: reopened, client: AIClient()).retrieve(plan: plan)
        XCTAssertTrue(results.contains { $0.id == old.id })
        XCTAssertLessThanOrEqual(results.count, 24)
    }

    func testSkipMovesThirtySecondsAndClampsAtLibraryEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root)
        var moments: [Moment] = []
        for index in 0...30 {
            let moment = Moment(id: "frame-\(index)", timestamp: Date(timeIntervalSince1970: Double(index * 3)), appName: "Fixture")
            moments.append(moment); try await store.insert(moment)
        }
        let backward = try await store.skip(from: moments[20], earlier: true)
        let forward = try await store.skip(from: moments[20], earlier: false)
        let beginning = try await store.skip(from: moments[2], earlier: true)
        let last = try await store.skip(from: moments[30], earlier: false)
        XCTAssertEqual(backward?.id, moments[10].id)
        XCTAssertEqual(forward?.id, moments[30].id)
        XCTAssertEqual(beginning?.id, moments[0].id)
        XCTAssertNil(last)
    }
}
