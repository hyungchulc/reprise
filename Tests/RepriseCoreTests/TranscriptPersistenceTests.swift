import SQLCipher
import XCTest
@testable import RepriseCore

final class TranscriptPersistenceTests: XCTestCase {
    func testLegacyDatabaseMigratesWithoutLosingTextOrMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        let sql = """
            CREATE TABLE moments (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, app_name TEXT NOT NULL,
                bundle_id TEXT NOT NULL, window_title TEXT NOT NULL, text TEXT NOT NULL,
                image_path TEXT NOT NULL, thumbnail_path TEXT NOT NULL, video_path TEXT,
                video_offset REAL, bookmarked INTEGER NOT NULL, kind TEXT NOT NULL, byte_count INTEGER NOT NULL);
            INSERT INTO moments VALUES ('legacy',123,'Meeting','','Old meeting','Saved transcript','','','meetings/old.m4a',NULL,0,'meeting',42);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let store = try MomentStore(root: root, keys: testKeys)
        XCTAssertTrue(store.convertedFromPlaintext)
        XCTAssertFalse(MomentStore.isPlaintextDatabase(root.appendingPathComponent("library.sqlite").path))
        XCTAssertNil(FileManager.default.contents(atPath: root.appendingPathComponent("library.sqlite").path)?.range(of: Data("Saved transcript".utf8)))
        let old = try await store.moment(id: "legacy")
        XCTAssertEqual(old?.text, "Saved transcript")
        XCTAssertEqual(old?.videoPath, "meetings/old.m4a")
        XCTAssertNil(old?.transcriptSegments)
        XCTAssertNil(old?.audioDuration)
        let cues = [TranscriptSegment(start: 2, end: 12, text: "First sentence"), TranscriptSegment(start: 54, end: 78, text: "Later chunk")]
        let timed = Moment(id: "timed", appName: "Meeting", text: "First sentence\nLater chunk", kind: "meeting", audioDuration: 80, transcriptSegments: cues)
        try await store.insert(timed)
        let reopened = try MomentStore(root: root, keys: testKeys)
        let stored = try await reopened.moment(id: "timed")
        XCTAssertEqual(stored?.transcriptSegments, cues)
        XCTAssertEqual(stored?.audioDuration, 80)
        let matches = try await reopened.search(MomentQuery(text: "Later chunk"))
        XCTAssertEqual(matches.map(\.id), ["timed"])
        var invalid = timed
        invalid.transcriptSegments = [TranscriptSegment(start: -1, end: 2, text: "invalid"), TranscriptSegment(start: .nan, end: 2, text: "invalid")]
        invalid.audioDuration = .infinity
        try await reopened.insert(invalid)
        let sanitized = try await reopened.moment(id: "timed")
        XCTAssertEqual(sanitized?.transcriptSegments, [])
        XCTAssertNil(sanitized?.audioDuration)
        try await reopened.updateTranscript(id: "timed", text: "Updated transcript", segments: cues, note: "Partial transcript")
        let updated = try await reopened.moment(id: "timed")
        XCTAssertEqual(updated?.text, "Updated transcript")
        XCTAssertEqual(updated?.transcriptionNote, "Partial transcript")
        try await reopened.delete(ids: ["timed"])
        try await reopened.updateTranscript(id: "timed", text: "Late completion", segments: cues, note: nil)
        let deleted = try await reopened.moment(id: "timed")
        XCTAssertNil(deleted)
    }

    func testLegacyJSONDoesNotRequireTranscriptMetadata() throws {
        let data = try JSONEncoder().encode(Moment(id: "old", appName: "Meeting", kind: "meeting"))
        let decoded = try JSONDecoder().decode(Moment.self, from: data)
        XCTAssertNil(decoded.transcriptSegments)
        XCTAssertNil(decoded.audioDuration)
    }
}
