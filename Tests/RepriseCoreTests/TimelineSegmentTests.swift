import XCTest
@testable import RepriseCore

final class TimelineSegmentTests: XCTestCase {
    func testAudioKeepsDurationAndSeparateIdentityAcrossScreenCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-audio-rail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        let start = Date(timeIntervalSince1970: 1000)
        let recording = Moment(id: "audio", timestamp: start, appName: "Meeting", kind: "meeting", audioDuration: 120)
        let second = Moment(id: "audio-2", timestamp: start.addingTimeInterval(120), appName: "Meeting", kind: "meeting", audioDuration: 30)
        let screen = Moment(id: "screen", timestamp: start.addingTimeInterval(3), appName: "App")
        for moment in [recording, second, screen] { try await store.insert(moment) }
        let axis = try await store.timelineOverview(around: start, span: 600)
        let audio = TimelineSegment.make(from: axis.entries, captureInterval: 3).filter { $0.kind == "meeting" }
        XCTAssertEqual(audio.map(\.id), ["audio", "audio-2"])
        XCTAssertEqual(audio[0].end.timeIntervalSince(audio[0].start), 120)
        XCTAssertEqual(audio[1].end.timeIntervalSince(audio[1].start), 30)
    }

    func testAppRunsMergeButIdleGapsAndDifferentAppsDoNot() {
        let origin = Date(timeIntervalSince1970: 1000)
        func moment(_ id: String, _ offset: Double, _ bundle: String) -> Moment {
            Moment(id: id, timestamp: origin.addingTimeInterval(offset), appName: bundle, bundleID: bundle)
        }
        let segments = TimelineSegment.make(from: [moment("d", 900, "A"), moment("c", 6, "B"),
            moment("b", 3, "A"), moment("a", 0, "A")], captureInterval: 3)
        XCTAssertEqual(segments.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(segments[0].end.timeIntervalSince(origin), 6)
        XCTAssertEqual(segments[1].end.timeIntervalSince(origin), 9)
        XCTAssertEqual(segments[2].end.timeIntervalSince(origin), 903)
    }

    func testAdjacentPagingHandlesEqualTimestamps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-adjacent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        let timestamp = Date(timeIntervalSince1970: 1000)
        let a = Moment(id: "a", timestamp: timestamp, appName: "A")
        let b = Moment(id: "b", timestamp: timestamp, appName: "B")
        try await store.insert(a); try await store.insert(b)
        let earlier = try await store.adjacent(to: b, earlier: true)
        let later = try await store.adjacent(to: a, earlier: false)
        let edge = try await store.adjacent(to: a, earlier: true)
        XCTAssertEqual(earlier?.id, "a"); XCTAssertEqual(later?.id, "b"); XCTAssertNil(edge)
    }
}
