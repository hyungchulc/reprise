import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import RepriseCore
@testable import Reprise

final class MemoryAudioTests: XCTestCase {
    @MainActor func testAudioOpensSeeksAndReleasesWithoutVideoPlayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 48_000)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let moment = Moment(appName: "Meeting", windowTitle: "Synthetic recording", text: "Synthetic transcript", videoPath: "silence.wav", kind: "meeting")
        let audio = MemoryAudioPlayer()
        defer { audio.unload() }
        await audio.load(moment: moment, root: root)
        XCTAssertTrue(audio.canPlay, audio.error ?? "Audio unavailable")
        XCTAssertEqual(audio.duration, 2, accuracy: 0.01)
        XCTAssertFalse(audio.isPlaying, "Opening a recording must not auto-play")
        let recorder = MeetingRecorder(store: try MomentStore(root: root), root: root, languages: SpeechLanguages())
        let view = NSHostingView(rootView: MemoryAudioPanel(moment: moment, audio: audio, recorder: recorder, transcriptExpanded: .constant(true), transcriptHeight: 160))
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 260)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        audio.seek(to: 500); XCTAssertEqual(audio.position, 2)
        audio.seek(to: -5); XCTAssertEqual(audio.position, 0)
        audio.seek(to: .nan); XCTAssertEqual(audio.position, 0)
        audio.togglePlayback(); XCTAssertTrue(audio.isPlaying)
        audio.pause(); XCTAssertFalse(audio.isPlaying)
        await audio.load(moment: Moment(appName: "Screen"), root: root)
        XCTAssertFalse(audio.canPlay)
        XCTAssertEqual(audio.duration, 0)
        XCTAssertFalse(audio.isPlaying)
    }

    @MainActor func testMissingAndCorruptAudioFailWithoutCrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not audio".utf8).write(to: root.appendingPathComponent("bad.m4a"))
        let audio = MemoryAudioPlayer()
        defer { audio.unload() }
        for path in ["missing.m4a", "bad.m4a", "../outside.m4a"] {
            await audio.load(moment: Moment(appName: "Meeting", videoPath: path, kind: "meeting"), root: root)
            XCTAssertFalse(audio.canPlay)
            XCTAssertNotNil(audio.error)
            XCTAssertFalse(audio.isLoading)
        }
        XCTAssertEqual(MemoryAudioPanel.timestamp(.nan), "0:00")
        XCTAssertEqual(MemoryAudioPanel.timestamp(3_661), "1:01:01")
    }

    @MainActor func testHistoryRestoresAcrossFilterChangesWithoutCallingProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-answer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = Moment(id: "saved", appName: "Meeting", text: "Original", kind: "meeting")
        let response = AIResponse(text: "Saved answer [1]", citations: [AICitation(momentID: "saved", label: "1")], usage: UsageEntry(provider: "grok", model: "old-model"))
        var history = SearchHistory()
        history.record("original question", result: SavedSearchResult(response: response, moments: [memory], appName: "Meeting", kind: "meeting"))
        history.record("legacy question")
        try history.save(root: root)
        let model = try AppModel(root: root)
        defer { model.shutdown() }
        try await model.store.insert(memory)
        model.provider.executablePath = "/nonexistent/no-inference-allowed"
        await model.restoreSearch("original question")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.response, response)
        XCTAssertEqual(model.displayedMatches.map(\.id), [memory.id])
        XCTAssertEqual(model.mode, "meetings")
        XCTAssertEqual(model.appFilter, "Meeting")
        XCTAssertNotNil(model.restoredSearchDate)
        XCTAssertEqual(model.search, "")
        XCTAssertEqual(model.searchTurns.map(\.question), ["original question"])
        XCTAssertFalse(model.asking)
        let usage = try await model.store.usage(since: nil)
        XCTAssertTrue(usage.isEmpty)
        model.endSearchSession()
        XCTAssertEqual(model.search, "")
        XCTAssertNil(model.response)
        await model.restoreSearch("legacy question")
        XCTAssertNil(model.response)
        XCTAssertNotNil(model.searchNotice)
        XCTAssertFalse(model.asking)
        await model.restoreSearch("original question")
        model.search = "what happened next?"
        XCTAssertEqual(model.response, response, "Follow-up drafting must keep the answer and sources visible")
        XCTAssertEqual(model.searchTurns.count, 1)
        model.searchPresented = true
        XCTAssertTrue(model.dismissSearch())
        XCTAssertFalse(model.searchPresented)
        XCTAssertEqual(model.response, response, "First Escape keeps the search available to reopen")
        XCTAssertFalse(model.dismissSearch(), "The second Escape can close the overlay")
        model.startNewSearch()
        XCTAssertEqual(model.search, "")
        XCTAssertTrue(model.searchTurns.isEmpty)
        XCTAssertNil(model.response)
        XCTAssertNil(model.restoredSearchDate)
    }
}
