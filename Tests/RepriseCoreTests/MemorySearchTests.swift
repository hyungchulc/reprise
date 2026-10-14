import XCTest
@testable import RepriseCore

final class MemorySearchTests: XCTestCase {
    func testWholeDayOverviewPreservesMorningAcrossLongRecentText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-overview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<120 {
            try await store.insert(Moment(id: "activity-\(index)", timestamp: origin.addingTimeInterval(Double(index * 900)),
                appName: "Fixture", windowTitle: "Activity \(index)", text: String(repeating: "Evidence \(index) ", count: 1000)))
        }
        for index in 0..<200 {
            try await store.insert(Moment(id: "repeat-\(index)", timestamp: origin.addingTimeInterval(Double(119 * 900 + index)),
                appName: "Fixture", windowTitle: "Activity 119", text: "Repeated recent frame"))
        }
        let overview = try await store.activityOverview(MomentQuery(limit: 96))
        XCTAssertEqual(overview.coverage?.totalRecords, 320)
        XCTAssertEqual(overview.moments.count, 96)
        XCTAssertEqual(overview.moments.first?.id, "activity-0")
        XCTAssertGreaterThanOrEqual(overview.moments.last!.timestamp, origin.addingTimeInterval(119 * 900))
        let evidence = try AIEvidenceInput(question: "what happened?", moments: overview.moments, maximumMoments: 96)
        XCTAssertEqual(evidence.citations.count, 96)
        XCTAssertEqual(evidence.citations.first?.momentID, "activity-0")
        XCTAssertLessThan(evidence.prompt.count, 40 * 1024)
        let morning = try await store.activityOverview(MomentQuery(appName: "Fixture", since: origin, until: origin.addingTimeInterval(4 * 900), limit: 96))
        XCTAssertEqual(morning.coverage?.totalRecords, 5)
        XCTAssertEqual(morning.moments.count, 5)
        let excluded = try await store.activityOverview(MomentQuery(appName: "Missing", limit: 96))
        XCTAssertTrue(excluded.moments.isEmpty)
        XCTAssertNil(excluded.coverage)
        XCTAssertTrue(try plan(["terms": [], "scope": "overview"]).isOverview)
        XCTAssertFalse(try plan(["scope": "invented"]).isOverview)
    }

    func testFollowUpRehydratesOriginalEvidenceWithinCurrentFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-followup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        let memory = Moment(id: "original", timestamp: Date(timeIntervalSince1970: 200), appName: "Fixture", text: "original details", kind: "meeting")
        try await store.insert(memory)
        for index in 0..<30 { try await store.insert(Moment(id: "other-\(index)", appName: "Other", text: "next topic")) }
        let previous = MemorySearchTurn(question: "what was discussed?", response: AIResponse(text: "Prior answer [M2]", citations: [AICitation(momentID: memory.id, label: "M2")], usage: UsageEntry(provider: "fixture", model: "fixture")))
        let engine = MemorySearch(store: store, client: AIClient())
        let rows = try await engine.retrieve(plan: plan(["terms": ["next"]]), conversation: [previous])
        XCTAssertEqual(rows.first?.id, memory.id)
        let bounded = try AIEvidenceInput(question: "and then?", moments: rows, conversation: [previous])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bounded.prompt) as? [String: Any])
        let context = try XCTUnwrap(payload["conversation"] as? [[String: Any]])
        let mapping = try XCTUnwrap(context.first?["citationMapping"] as? [[String: String]])
        XCTAssertEqual(mapping, [["previousLabel": "M2", "currentEvidenceLabel": "M1"]])
        let excluded = try await engine.retrieve(plan: plan(["terms": ["next"]]), filter: MomentQuery(appName: "Other"), conversation: [previous])
        XCTAssertFalse(excluded.contains { $0.id == memory.id })
        try await store.delete(ids: [memory.id])
        let deleted = try await engine.retrieve(plan: plan(), conversation: [previous])
        XCTAssertFalse(deleted.contains { $0.id == memory.id })
    }

    func testFollowUpContextHasBoundedHistoryAndNoMediaPaths() throws {
        let response = AIResponse(text: String(repeating: "한", count: 5000), citations: [], usage: UsageEntry(provider: "fixture", model: "fixture"))
        let turns = (0..<20).map { MemorySearchTurn(question: "Question \($0)", response: response) }
        let input = try AIEvidenceInput(question: "more?", moments: [Moment(appName: "Fixture", text: "Evidence", imagePath: "/private/not-in-prompt")], conversation: turns)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: input.prompt) as? [String: Any])
        let context = try XCTUnwrap(payload["conversation"] as? [[String: Any]])
        XCTAssertEqual(context.count, 4)
        XCTAssertEqual(context.first?["question"] as? String, "Question 16")
        XCTAssertLessThan(input.prompt.count, 20 * 1024)
        XCTAssertFalse(String(decoding: input.prompt, as: UTF8.self).contains("not-in-prompt"))
        XCTAssertFalse(String(decoding: input.prompt, as: UTF8.self).contains("\u{FFFD}"))
    }

    func testUncitedAnswerCannotBecomeGeneralChat() {
        let usage = UsageEntry(provider: "fixture", model: "fixture", durationSeconds: 0)
        let ungrounded = MemorySearch.grounded(AIResponse(text: "Test received", citations: [], usage: usage))
        XCTAssertTrue(ungrounded.text.contains("No supporting memories"))
        let citation = AICitation(momentID: "real-record", label: "M1")
        let grounded = MemorySearch.grounded(AIResponse(text: "The recorded code is 714 [M1].", citations: [citation], usage: usage))
        XCTAssertEqual(grounded.citations.first?.momentID, "real-record")
        XCTAssertEqual(grounded.text, "The recorded code is 714 [M1].")
    }

    func testModelListAcceptsOnlyCatalogRows() {
        let models = AIClient.grokModels("You are logged in with grok.com.\nDefault model: grok-4.7\n  - grok-4.6\n  * grok-4.7 (default)\n  - grok-4.7\n  - invalid\n")
        XCTAssertEqual(models.map(\.id), ["grok-4.6", "grok-4.7"])
    }

    func testLiveSearchWithSyntheticMemoryWhenRequested() async throws {
        guard let name = ProcessInfo.processInfo.environment["REPRISE_VERIFY_PROVIDER"], let kind = AIProviderKind(rawValue: name) else { throw XCTSkip("Explicit opt-in only") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-live-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        try await store.insert(Moment(id: "synthetic-evidence", appName: "Synthetic Verification", windowTitle: "Test record", text: "In this synthetic test record, the validation code for Project Marigold is 714. This is not a real personal memory."))
        if let question = ProcessInfo.processInfo.environment["REPRISE_VERIFY_QUESTION"] {
            try await store.insert(Moment(id: "synthetic-today", timestamp: Date().addingTimeInterval(-600), appName: "Notes", windowTitle: "메모",
                                          text: "오늘 회의에서 예산 초안을 검토했고 금요일까지 수정하기로 했다. This is a synthetic test record."))
            // REPRISE_VERIFY_SPREAD fills today with that many synthetic activities, like a full day.
            let environment = ProcessInfo.processInfo.environment
            let spread = Int(environment["REPRISE_VERIFY_SPREAD"] ?? "") ?? 0
            let start = Calendar.current.startOfDay(for: Date()), span = Date().timeIntervalSince(start)
            let apps = ["Safari", "Notes", "Mail", "Xcode", "Slack", "Calendar"]
            for index in 0..<spread {
                try await store.insert(Moment(id: "synthetic-\(index)", timestamp: start.addingTimeInterval(span * Double(index + 1) / Double(spread + 2)),
                    appName: apps[index % apps.count], windowTitle: "Synthetic task \(index)",
                    text: "Synthetic test record \(index): worked on item \(index) of the sample plan. 합성 테스트 기록 \(index)번: 샘플 계획의 \(index)번 항목을 작업했다."))
            }
            let configuration = AIProviderConfiguration(provider: kind, model: environment["REPRISE_VERIFY_MODEL"] ?? "",
                                                        reasoningEffort: environment["REPRISE_VERIFY_EFFORT"],
                                                        fast: environment["REPRISE_VERIFY_FAST"] == "1" ? true : nil,
                                                        contextWindow: Int(environment["REPRISE_VERIFY_WINDOW"] ?? ""))
            let result = try await MemorySearch(store: store, client: AIClient()).search(question: question, configuration: configuration)
            print("ANSWER", result.response.text)
            print("CONTEXT", result.response.context.map { "\($0.tokens) of \($0.window.map(String.init) ?? "unknown")" } ?? "none")
            return
        }
        let result = try await MemorySearch(store: store, client: AIClient()).search(question: "What was the validation code for Project Marigold?", configuration: AIProviderConfiguration(provider: kind))
        XCTAssertTrue(result.response.text.contains("714"))
        XCTAssertEqual(result.moments.map(\.id), ["synthetic-evidence"])
        XCTAssertEqual(result.usage.count, 2)
    }

    private func plan(_ fields: [String: Any] = [:]) throws -> MemorySearchPlan {
        var payload: [String: Any] = ["terms": ["budget", "forecast"], "since": NSNull(), "until": NSNull(),
                                     "kind": NSNull()]
        payload.merge(fields) { _, new in new }
        return try MemorySearchPlan(payload: payload, timeZone: TimeZone(identifier: "Europe/Stockholm")!)
    }

    func testPlanKeepsUsableFieldsAndRepairsSameDayRanges() throws {
        XCTAssertThrowsError(try MemorySearchPlan(payload: ["terms": ["budget"]], timeZone: .current))
        XCTAssertThrowsError(try plan(["terms": "budget"]))
        let blank = try plan(["terms": [" "]])
        XCTAssertTrue(blank.terms.isEmpty)
        XCTAssertTrue(blank.isOverview)
        XCTAssertNil(try plan(["since": "2026-02-30"]).since)
        XCTAssertNil(try plan(["kind": "invented"]).kind)
        // On-device models answer "today" as since and until the same day.
        let sameDay = try plan(["since": "2026-10-14", "until": "2026-10-14"])
        XCTAssertEqual(sameDay.until!.timeIntervalSince(sameDay.since!), 24 * 3600)
        let reversed = try plan(["since": "2026-10-13", "until": "2026-10-12"])
        XCTAssertNotNil(reversed.since)
        XCTAssertNil(reversed.until)
        XCTAssertEqual(try plan(["since": "2026-10-13T10:00:00"]).since, ISO8601DateFormatter().date(from: "2026-10-13T08:00:00Z"))
    }

    func testQuestionTimeWordsFillAMissingRange() throws {
        var searchPlan = try plan(["terms": ["회의"]])
        let now = ISO8601DateFormatter().date(from: "2026-10-14T13:30:00Z")!
        searchPlan.fillTime(from: "어제 회의 뭐였지?", now: now, timeZone: TimeZone(identifier: "Europe/Stockholm")!)
        XCTAssertEqual(searchPlan.since, ISO8601DateFormatter().date(from: "2026-10-12T22:00:00Z"))
        XCTAssertEqual(searchPlan.until, ISO8601DateFormatter().date(from: "2026-10-13T22:00:00Z"))
    }

    func testVisibleFiltersRemainHardConstraintsIncludingFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-filter-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        for (id, app, kind, time) in [("match", "Fixture", "meeting", 200.0), ("outside", "Fixture", "meeting", 100.0),
                                      ("app", "Other", "meeting", 200.0), ("kind", "Fixture", "screen", 200.0)] {
            try await store.insert(Moment(id: id, timestamp: Date(timeIntervalSince1970: time), appName: app, text: "forecast", kind: kind))
        }
        let filter = MomentQuery(appName: "Fixture", since: Date(timeIntervalSince1970: 150), until: Date(timeIntervalSince1970: 250), kind: "meeting")
        let engine = MemorySearch(store: store, client: AIClient())
        for terms in [["forecast"], ["absent"]] {
            let rows = try await engine.retrieve(plan: plan(["terms": terms, "kind": "screen"]), filter: filter)
            XCTAssertEqual(rows.map(\.id), ["match"])
        }
        let intersection = try plan(["since": "2026-10-13", "until": "2026-10-14"]).query(text: "", limit: 24, filter: filter)
        XCTAssertGreaterThan(intersection.since!, intersection.until!)
        let empty = try await store.query(intersection)
        XCTAssertTrue(empty.isEmpty)
    }

    func testLocalDayHonorsDSTAndExclusiveEnd() throws {
        let spring = try plan(["since": "2026-03-29", "until": "2026-03-30"])
        XCTAssertEqual(spring.until!.timeIntervalSince(spring.since!), 23 * 3600)
        XCTAssertLessThan(spring.query(text: "", limit: 24).until!, spring.until!)
    }

    func testAlternativeRetrievalFindsOldEvidenceWithoutQuestionGlue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-search-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        let old = Moment(id: "old", timestamp: Date(timeIntervalSince1970: 100), appName: "Fixture", text: "quarterly forecast")
        try await store.insert(old)
        for i in 0..<40 {
            try await store.insert(Moment(id: "new-\(i)", timestamp: Date(timeIntervalSince1970: Double(200 + i)),
                                          appName: "Fixture", text: "unrelated screenshot"))
        }
        let engine = MemorySearch(store: store, client: AIClient())
        let rows = try await engine.retrieve(plan: plan())
        XCTAssertEqual(rows.first?.id, "old")
        XCTAssertLessThanOrEqual(rows.count, 24)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}
