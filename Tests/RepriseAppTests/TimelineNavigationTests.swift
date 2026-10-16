import AppKit
import XCTest
import RepriseCore
@testable import Reprise

final class TimelineNavigationTests: XCTestCase {
    func testScrollAxesUseNativeDeltas() {
        XCTAssertEqual(MemoryTimeline.scrollOffset(x: 0, y: -3, precise: true), -12)
        XCTAssertEqual(MemoryTimeline.scrollOffset(x: 0, y: 3, precise: true), 12)
        XCTAssertEqual(MemoryTimeline.scrollOffset(x: 3, y: 1, precise: true), -12)
        XCTAssertEqual(MemoryTimeline.scrollOffset(x: -3, y: 1, precise: true), 12)
        XCTAssertEqual(MemoryTimeline.scrollOffset(x: 0, y: -1, precise: false), -40)
    }

    @MainActor func testContinuousInputLoadsOlderHistoryBeforeGestureEnds() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, keys: testKeys)
        defer { model.shutdown() }
        for index in 0..<360 {
            try await model.store.insert(Moment(id: "frame-\(index)", timestamp: Date(timeIntervalSince1970: Double(index * 10)), appName: "Fixture"))
        }
        await model.reload()
        XCTAssertEqual(model.moments.count, 200)
        let initialOldest = try XCTUnwrap(model.moments.last?.timestamp)
        var movedBeyondInitialWindow = false
        for index in 0..<85 {
            model.scrollTimeline(x: 0, y: -8, precise: true)
            try await Task.sleep(for: .milliseconds(5))
            if index < 80, let selected = model.selection, selected.timestamp < initialOldest { movedBeyondInitialWindow = true }
        }
        XCTAssertTrue(movedBeyondInitialWindow, "History loading must not debounce forever during a gesture")
        try await settle { abs((model.selection?.timestamp.timeIntervalSince1970 ?? 0) - 870) <= 5 }
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 870)
        let window = try await model.store.timeline(around: Date(timeIntervalSince1970: 1605), countPerSide: 2)
        XCTAssertEqual(window.map(\.id), ["frame-162", "frame-161", "frame-160", "frame-159"])
    }

    @MainActor func testCursorAccumulatesAcrossSparseFramesAndReversesAtBounds() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, keys: testKeys)
        defer { model.shutdown() }
        for time in [0, 200] {
            try await model.store.insert(Moment(id: "frame-\(time)", timestamp: Date(timeIntervalSince1970: Double(time)), appName: "Fixture"))
        }
        await model.reload()
        for _ in 0..<6 { model.scrollTimeline(x: 0, y: -5, precise: true) }
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 80)
        XCTAssertEqual(model.selection?.id, "frame-0")
        model.scrollTimeline(x: 0, y: -10_000, precise: true)
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 0)
        model.scrollTimeline(x: 0, y: 2.5, precise: true)
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 10)
        model.scrollTimeline(x: 0, y: 10_000, precise: true)
        model.scrollTimeline(x: 0, y: -2.5, precise: true)
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 190)
        model.select(try XCTUnwrap(model.moments.last))
        model.scrollTimeline(x: 0, y: 2.5, precise: true)
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 10)
    }

    @MainActor func testLongRecordingGapMovesDirectlyToAdjacentSession() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, keys: testKeys)
        defer { model.shutdown() }
        for time in [0, 30, 32_730, 32_760] {
            try await model.store.insert(Moment(id: "frame-\(time)", timestamp: Date(timeIntervalSince1970: Double(time)), appName: "Fixture"))
        }
        await model.reload()
        XCTAssertEqual(model.timelineAxis.positions, [0, 30, 62, 92])
        await model.jump(to: Date(timeIntervalSince1970: 32_730))
        model.scrollTimeline(x: 0, y: -1, precise: true)
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 30)
        XCTAssertEqual(model.selection?.id, "frame-30")
        model.scrollTimeline(x: 0, y: 1, precise: true)
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 32_730)
        XCTAssertEqual(model.selection?.id, "frame-32730")
        model.moveTimeline(from: Date(timeIntervalSince1970: 32_760), by: -80)
        XCTAssertEqual(model.timelineDate?.timeIntervalSince1970, 12)
    }

    @MainActor func testOverviewFillsBothViewportSidesBeyondPreviewWindow() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, keys: testKeys)
        defer { model.shutdown() }
        model.setTimelineViewport(width: 2_000)
        for index in 0..<1_200 {
            try await model.store.insert(Moment(id: "frame-\(index)", timestamp: Date(timeIntervalSince1970: Double(index * 10)), appName: "Fixture", text: String(repeating: "body ", count: 200)))
        }
        await model.reload()
        XCTAssertEqual(model.moments.count, 200)
        XCTAssertGreaterThan(model.timelineAxis.entries.count, 400)
        await model.jump(to: Date(timeIntervalSince1970: 6_000))
        let center = model.timelineAxis.position(of: try XCTUnwrap(model.timelineDate))
        XCTAssertGreaterThanOrEqual(center, 4_000)
        XCTAssertGreaterThanOrEqual(model.timelineAxis.extent - center, 4_000)
        XCTAssertLessThanOrEqual(model.moments.count, 240, "Wide rail metadata must not load all OCR bodies")
    }

    @MainActor func testManualSelectionWinsOverPendingHistoryLoad() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(root: root, keys: testKeys)
        defer { model.shutdown() }
        for index in 0..<250 {
            try await model.store.insert(Moment(id: "frame-\(index)", timestamp: Date(timeIntervalSince1970: Double(index * 10)), appName: "Fixture"))
        }
        await model.reload()
        let newest = try XCTUnwrap(model.selection)
        model.scrub(to: Date(timeIntervalSince1970: 50))
        await Task.yield()
        model.select(newest)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.selection?.id, newest.id)
        XCTAssertEqual(model.timelineDate, newest.timestamp)
    }

    @MainActor func testPreviewPublishesWhileInputContinuesAndDropsQueuedIntermediateFrames() async throws {
        var decoded: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        var releaseLast: CheckedContinuation<Void, Never>?
        let loader = MemoryImageLoader { url, _, _ in
            decoded.append(url.lastPathComponent)
            if decoded.count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            else { await withCheckedContinuation { releaseLast = $0 } }
            return NSImage(size: NSSize(width: 2, height: 2))
        }
        defer { loader.cancel() }
        loader.request(key: "first", url: URL(fileURLWithPath: "/first"), maxPixels: 4000, keepsPreviousImage: true)
        await Task.yield()
        for index in 0..<50 {
            loader.request(key: "frame-\(index)", url: URL(fileURLWithPath: "/frame-\(index)"), maxPixels: 4000, keepsPreviousImage: true)
        }
        releaseFirst?.resume()
        try await settle { releaseLast != nil }
        XCTAssertEqual(loader.loadedKey, "first", "A completed preview must not be discarded merely because input continues")
        XCTAssertEqual(decoded, ["first", "frame-49"])
        releaseLast?.resume()
        try await settle { loader.loadedKey == "frame-49" }
    }

    @MainActor func testCancelledPreviewCannotPublish() async throws {
        var release: CheckedContinuation<Void, Never>?
        let loader = MemoryImageLoader { _, _, _ in
            await withCheckedContinuation { release = $0 }
            return NSImage(size: NSSize(width: 2, height: 2))
        }
        loader.request(key: "old", url: URL(fileURLWithPath: "/old"), maxPixels: 4000, keepsPreviousImage: true)
        try await settle { release != nil }
        loader.clear()
        release?.resume()
        await Task.yield()
        XCTAssertNil(loader.image)
        XCTAssertEqual(loader.loadedKey, "")
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reprise-timeline-\(UUID().uuidString)") }

    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for bounded timeline work")
    }
}
