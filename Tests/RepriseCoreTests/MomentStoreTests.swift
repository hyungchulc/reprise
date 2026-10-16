import Foundation
import XCTest
@testable import RepriseCore

final class MomentStoreTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepriseStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPersistenceTimeRangeReopeningAndBookmarkCache() async throws {
        let root = try temporaryRoot()
        let store = try MomentStore(root: root, keys: testKeys)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Moment(id: "first", timestamp: timestamp, appName: "Editor", text: "original text\0tail", videoPath: "clips/screen.mov", videoOffset: 4.5, byteCount: 12)
        try await store.insert(first)
        // A recording nearer than any screen: the timeline steps past it and opens it only from its lane.
        try await store.insert(Moment(id: "recording", timestamp: timestamp.addingTimeInterval(-50), appName: "Meeting", text: "", kind: "meeting"))
        try await store.insert(Moment(id: "later", timestamp: timestamp.addingTimeInterval(1), appName: "Browser", text: "later text"))
        _ = try await store.moment(id: "first")
        let reopened = try MomentStore(root: root, keys: testKeys)
        let found = try await reopened.moment(id: "first")
        XCTAssertEqual(found, first)
        let range = try await reopened.query(MomentQuery(since: timestamp, until: timestamp))
        XCTAssertEqual(range.map(\.id), ["first"])
        let page = try await reopened.query(MomentQuery(limit: 1, offset: 1))
        XCTAssertEqual(page.map(\.id), ["first"])
        let nearestBefore = try await reopened.nearest(to: timestamp.addingTimeInterval(-100))
        let nearestAfter = try await reopened.nearest(to: timestamp.addingTimeInterval(100))
        let nearestTie = try await reopened.nearest(to: timestamp.addingTimeInterval(0.5))
        let nearestExact = try await reopened.nearest(to: timestamp.addingTimeInterval(1))
        XCTAssertEqual(nearestBefore?.id, "first")
        XCTAssertEqual(nearestAfter?.id, "later")
        XCTAssertEqual(nearestTie?.id, "first")
        XCTAssertEqual(nearestExact?.id, "later")
        try await reopened.setBookmarked(id: "first", value: true)
        let bookmarked = try await reopened.moment(id: "first")
        XCTAssertEqual(bookmarked?.isBookmarked, true)
        let crossConnection = try await store.moment(id: "first")
        XCTAssertEqual(crossConnection?.isBookmarked, true)
        let bookmarks = try await reopened.query(MomentQuery(appName: "Editor", bookmarkedOnly: true, kind: "screen"))
        XCTAssertEqual(bookmarks.map(\.id), ["first"])
        var updated = first
        updated.text = "replacement content"
        try await reopened.insert(updated)
        let oldMatches = try await reopened.query(MomentQuery(text: "original"))
        let newMatches = try await reopened.query(MomentQuery(text: "replacement"))
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(newMatches.map(\.id), ["first"])
        try await reopened.delete(ids: ["first"])
        let deleted = try await reopened.moment(id: "first")
        XCTAssertNil(deleted)
        let deletedMatches = try await reopened.query(MomentQuery(text: "replacement"))
        XCTAssertTrue(deletedMatches.isEmpty)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let localDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: localDay))
        XCTAssertEqual(interval.duration, 25 * 3_600)
        let firstTwoThirty = interval.start.addingTimeInterval(2.5 * 3_600)
        let secondTwoThirty = interval.start.addingTimeInterval(3.5 * 3_600)
        XCTAssertEqual(calendar.component(.hour, from: firstTwoThirty), 2)
        XCTAssertEqual(calendar.component(.hour, from: secondTwoThirty), 2)
        try await reopened.insert(Moment(id: "dst-first", timestamp: firstTwoThirty, appName: "Calendar"))
        try await reopened.insert(Moment(id: "dst-second", timestamp: secondTwoThirty, appName: "Calendar"))
        try await reopened.insert(Moment(id: "next-midnight", timestamp: interval.end, appName: "Calendar"))
        // Query's until is inclusive, so use the preceding representable instant for a half-open local day.
        let dayQuery = MomentQuery(since: interval.start, until: Date(timeIntervalSince1970: interval.end.timeIntervalSince1970.nextDown))
        let dayMoments = try await reopened.query(dayQuery)
        XCTAssertEqual(dayMoments.map(\.id), ["dst-second", "dst-first"])
        let reopenedTime = try await reopened.nearest(to: secondTwoThirty)
        XCTAssertEqual(reopenedTime?.id, "dst-second")
        try await reopened.delete(ids: ["later", "dst-first", "dst-second", "next-midnight"])
        let emptyNearest = try await reopened.nearest(to: localDay)
        XCTAssertNil(emptyNearest)
    }

    func testSearchTreatsOperatorsQuotesAndPunctuationAsLiteralTokens() async throws {
        let store = try MomentStore(root: temporaryRoot(), keys: testKeys)
        try await store.insert(Moment(id: "literal", appName: "Notes", windowTitle: "Plan", text: "alpha OR beta don't 안녕"))
        try await store.insert(Moment(id: "other", appName: "Notes", text: "alpha gamma"))
        let operators = try await store.query(MomentQuery(text: "alpha OR beta"))
        XCTAssertEqual(operators.map(\.id), ["literal"])
        let punctuation = try await store.query(MomentQuery(text: "\"alpha\" : (beta*)"))
        XCTAssertEqual(punctuation.map(\.id), ["literal"])
        let unicode = try await store.query(MomentQuery(text: "don't 안녕"))
        XCTAssertEqual(unicode.map(\.id), ["literal"])
        for malformed in ["\"", "***", "NEAR(", "x' OR 1=1 --", "AND NOT", "{text}:"] {
            _ = try await store.query(MomentQuery(text: malformed))
        }
        let emptySyntax = try await store.query(MomentQuery(text: "\"***():"))
        XCTAssertTrue(emptySyntax.isEmpty)
    }

    func testWordsMatchWithKoreanParticlesAndPageAddressesAreSearchable() async throws {
        let store = try MomentStore(root: temporaryRoot(), keys: testKeys)
        try await store.insert(Moment(id: "korean", appName: "Notes", text: "내일 회의에서 예산을 정하자"))
        try await store.insert(Moment(id: "page", appName: "Safari", windowTitle: "Docs", text: "Overview",
                                      url: "https://developer.apple.com/documentation/foundationmodels?token=secret#top"))
        let particle = try await store.query(MomentQuery(text: "회의 예산"))
        XCTAssertEqual(particle.map(\.id), ["korean"])
        let address = try await store.query(MomentQuery(text: "foundationmodels"))
        XCTAssertEqual(address.map(\.id), ["page"])
        let saved = try await store.moment(id: "page")
        XCTAssertEqual(saved?.url, "https://developer.apple.com/documentation/foundationmodels")
        let short = try await store.query(MomentQuery(text: "doc"))
        XCTAssertTrue(short.isEmpty, "Short Latin words match whole words only")
    }

    func testDeletionPreservesSharedMediaAndRejectsEscapesIncludingReplacedSymlink() async throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        let store = try MomentStore(root: root, keys: testKeys)
        let shared = root.appendingPathComponent("shared.bin")
        try Data([1, 2, 3]).write(to: shared)
        try await store.insert(Moment(id: "a", appName: "Test", imagePath: "./shared.bin"))
        try await store.insert(Moment(id: "b", appName: "Test", videoPath: "shared.bin"))
        try await store.delete(ids: ["a", "missing", "a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        try await store.delete(ids: ["b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))

        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([4]).write(to: folder.appendingPathComponent("keep.bin"))
        let protected = outside.appendingPathComponent("keep.bin")
        try Data([9]).write(to: protected)
        try await store.insert(Moment(id: "replace", appName: "Test", imagePath: "media/keep.bin"))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        try await store.delete(ids: ["replace"])
        XCTAssertEqual(try Data(contentsOf: protected), Data([9]))
        for path in ["../keep.bin", protected.path, "media/keep.bin", "./library.sqlite", "x/../library.sqlite", "a\0b"] {
            do {
                try await store.insert(Moment(appName: "Test", imagePath: path))
                XCTFail("Accepted unsafe path \(path)")
            } catch is MomentStoreError { }
        }
        let remaining = try await store.stats()
        XCTAssertEqual(remaining.momentCount, 0)
    }

    /// After a capture the count reads only the new moments; it must match a full count.
    /// The mark of where screens without the menu bar begin is set once per library.
    func testScreensWithoutMenuBarBeginAtTheLibrarysFirstOpening() throws {
        let root = try temporaryRoot(), before = Date()
        let first = try XCTUnwrap(try MomentStore(root: root, keys: testKeys).screensWithoutMenuBarSince)
        XCTAssertEqual(first.timeIntervalSince1970, before.timeIntervalSince1970, accuracy: 5)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(try MomentStore(root: root, keys: testKeys).screensWithoutMenuBarSince, first)
        XCTAssertNil(try MomentStore(root: root, readOnly: true, keys: testKeys).screensWithoutMenuBarSince)
    }

    func testStatsAfterNewMomentsMatchAFullCount() async throws {
        let store = try MomentStore(root: try temporaryRoot(), keys: testKeys)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.insert(Moment(id: "a", timestamp: start, appName: "Notes", byteCount: 10))
        try await store.insert(Moment(id: "b", timestamp: start.addingTimeInterval(3), appName: "browser", byteCount: 20))
        let known = try await store.stats()
        try await store.insert(Moment(id: "c", timestamp: start.addingTimeInterval(6), appName: "Mail", byteCount: 30))
        try await store.insert(Moment(id: "d", timestamp: start.addingTimeInterval(9), appName: "Notes", byteCount: 40))
        let counted = try await store.stats(after: known), full = try await store.stats()
        XCTAssertEqual(counted.momentCount, full.momentCount)
        XCTAssertEqual(counted.storedBytes, full.storedBytes)
        XCTAssertEqual(counted.newest, full.newest)
        XCTAssertEqual(counted.oldest, full.oldest)
        XCTAssertEqual(counted.apps, full.apps)
        let unchanged = try await store.stats(after: full)
        XCTAssertEqual(unchanged.momentCount, full.momentCount)
    }

    func testRetentionAndBudgetPreserveBookmarksAndReportStats() async throws {
        let root = try temporaryRoot()
        let store = try MomentStore(root: root, keys: testKeys)
        let now = Date()
        try await store.insert(Moment(id: "old", timestamp: now.addingTimeInterval(-10 * 86_400), appName: "A", byteCount: 50))
        try await store.insert(Moment(id: "bookmark", timestamp: now.addingTimeInterval(-20 * 86_400), appName: "B", isBookmarked: true, byteCount: 30))
        try await store.insert(Moment(id: "recent", timestamp: now, appName: "C", byteCount: 40))
        let ageRemoved = try await store.prune(retentionDays: 7, maxBytes: 100)
        XCTAssertEqual(ageRemoved, 1)
        let budgetRemoved = try await store.prune(retentionDays: 7, maxBytes: 10)
        XCTAssertEqual(budgetRemoved, 1)
        let stats = try await store.stats()
        XCTAssertEqual(stats.momentCount, 1)
        XCTAssertEqual(stats.storedBytes, 30)
        XCTAssertGreaterThan(stats.databaseBytes, 0)
        XCTAssertEqual(stats.apps, ["B"])
        XCTAssertEqual(try XCTUnwrap(stats.oldest).timeIntervalSince1970, now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(stats.newest, stats.oldest)
        let bookmark = try await store.moment(id: "bookmark")
        XCTAssertEqual(bookmark?.isBookmarked, true)
    }

    func testUsageUnknownMetricsAndExportAllPagesWithFilters() async throws {
        let root = try temporaryRoot()
        let store = try MomentStore(root: root, keys: testKeys)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.recordUsage(UsageEntry(id: "unknown", timestamp: date, provider: "local", model: "test", durationSeconds: 1.25, succeeded: false))
        try await store.recordUsage(UsageEntry(id: "measured", timestamp: date.addingTimeInterval(1), provider: "local", model: "test", inputTokens: 123, outputTokens: 45, costUSD: 0.5))
        let usage = try await store.usage(since: nil)
        XCTAssertEqual(usage.map(\.id), ["measured", "unknown"])
        XCTAssertNil(usage.last?.inputTokens)
        XCTAssertNil(usage.last?.costUSD)
        XCTAssertEqual(usage.last?.succeeded, false)
        let recentUsage = try await store.usage(since: date.addingTimeInterval(0.5))
        XCTAssertEqual(recentUsage.map(\.id), ["measured"])
        for index in 0..<1_003 {
            try await store.insert(Moment(id: "m-\(index)", timestamp: date.addingTimeInterval(Double(index)), appName: "Export", text: "needle"))
        }
        try await store.insert(Moment(id: "excluded", appName: "Other", text: "needle"))
        let export = root.appendingPathComponent("export.json")
        try await store.export(to: export, query: MomentQuery(text: "needle", appName: "Export", limit: 1))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let moments = try decoder.decode([Moment].self, from: Data(contentsOf: export))
        XCTAssertEqual(moments.count, 1_003)
        XCTAssertEqual(moments.first?.id, "m-1002")
        XCTAssertEqual(moments.last?.id, "m-0")
        XCTAssertEqual(Set(moments.map(\.id)).count, moments.count)
        XCTAssertTrue(moments.allSatisfy { $0.appName == "Export" })
        do {
            try await store.export(to: root.appendingPathComponent("library.sqlite"), query: MomentQuery())
            XCTFail("Export overwrote the live database")
        } catch is MomentStoreError { }
        let afterRejectedExport = try await store.stats()
        XCTAssertEqual(afterRejectedExport.momentCount, 1_004)
    }
}
