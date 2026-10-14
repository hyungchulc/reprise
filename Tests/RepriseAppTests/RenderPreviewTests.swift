import AppKit
import SwiftUI
import XCTest
@testable import RepriseCore
@testable import Reprise

/// Renders new settings and panels to PNG files for a visual check, on request.
final class RenderPreviewTests: XCTestCase {
    @MainActor func testRenderTranscriptionViewsWhenRequested() async throws {
        guard let folder = ProcessInfo.processInfo.environment["REPRISE_RENDER"] else { throw XCTSkip("Set REPRISE_RENDER to a folder to render previews.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let model = try AppModel(root: root, keys: testKeys, models: root.appendingPathComponent("Models"))
        for engine in TranscriptionEngine.allCases {
            model.preferences.transcriptionEngine = engine
            model.preferences.speakerLabels = engine == .whisperKit
            let form = Form {
                Section("Transcription") { TranscriptionSettings(model: model, models: model.speechModels) }
                Section("Speakers") { SpeakerLabelSettings(model: model, models: model.speechModels) }
            }.formStyle(.grouped).frame(width: 592, height: 620)
            try render(form, to: URL(fileURLWithPath: folder).appendingPathComponent("audio-\(engine.rawValue).png"))
        }
        model.speechModels.cancel(model.preferences.whisperModel); model.speechModels.cancel("speakers")
        let segments = [TranscriptSegment(start: 0, end: 4, text: "오늘 회의를 시작하겠습니다.", speaker: "Speaker 1"),
                        TranscriptSegment(start: 4.5, end: 9, text: "Thanks. The design is ready.", speaker: "Mina"),
                        TranscriptSegment(start: 9.5, end: 12, text: "좋습니다. 일정은요?", speaker: "Speaker 1")]
        let moment = Moment(appName: "Meeting", windowTitle: "Weekly sync", text: SpeakerLabels.text(segments), kind: "meeting",
                            audioDuration: 12, transcriptSegments: segments)
        let recorder = MeetingRecorder(store: model.store, root: root, languages: SpeechLanguages(), speechModels: model.speechModels)
        let panel = MemoryAudioPanel(moment: moment, audio: MemoryAudioPlayer(), recorder: recorder, transcriptExpanded: .constant(true),
                                     transcriptHeight: 200, engine: .openAI)
        try render(panel.frame(width: 640).padding(), to: URL(fileURLWithPath: folder).appendingPathComponent("panel-speakers.png"))
    }

    @MainActor private func render(_ view: some View, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
