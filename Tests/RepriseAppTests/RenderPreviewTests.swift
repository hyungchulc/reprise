import AppKit
import SwiftUI
import XCTest
@testable import RepriseCore
@testable import Reprise
import RepriseMCPKit

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
            model.preferences.speakerLabels = engine == .whisperKit || engine == .gemini
            model.preferences.speakerFinder = engine == .gemini ? .openAI : .mac
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

    @MainActor func testRenderCaptionViewsWhenRequested() async throws {
        guard let folder = ProcessInfo.processInfo.environment["REPRISE_RENDER"] else { throw XCTSkip("Set REPRISE_RENDER to a folder to render previews.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let model = try AppModel(root: root, keys: testKeys, models: root.appendingPathComponent("Models"))
        for engine in CaptionEngine.allCases {
            model.preferences.captions.engine = engine
            model.preferences.captions.spoken = engine == .onDevice ? "sv-SE" : ""
            model.preferences.captions.showOriginal = engine == .automatic
            let form = Form { CaptionSettings(model: model, captions: model.captions) }.formStyle(.grouped).frame(width: 592, height: 1400)
            try render(form, to: URL(fileURLWithPath: folder).appendingPathComponent("captions-\(engine.rawValue).png"))
        }
        var style = model.preferences.captions
        style.showOriginal = true
        let captions = ZStack(alignment: .bottom) {
            Color(white: 0.25)
            VStack(spacing: 30) {
                CaptionBlock(text: "안녕하세요, 환영합니다. 오늘은 집에서 시나몬 롤을 어떻게 굽는지 이야기해 볼게요.",
                             spoken: "Hej och välkommen, idag pratar vi om hur man bakar kanelbullar hemma.", style: style, width: 1000)
                CaptionBlock(text: "Captions appear here", moving: true, style: model.preferences.captions, width: 1000)
                CaptionBlock(text: "", notice: "Captions in Korean, from Mac audio, with OpenAI", style: model.preferences.captions, width: 1000)
            }.padding(30)
        }.frame(width: 1080)
        try render(captions, to: URL(fileURLWithPath: folder).appendingPathComponent("captions-overlay.png"))
    }

    @MainActor func testRenderAssistantViewsWhenRequested() async throws {
        guard let folder = ProcessInfo.processInfo.environment["REPRISE_RENDER"] else { throw XCTSkip("Set REPRISE_RENDER to a folder to render previews.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let model = try AppModel(root: root, keys: testKeys, models: root.appendingPathComponent("Models"))
        model.preferences.assistant.servers = [MCPServerSetting(name: "Brave Search", command: "npx -y @brave/brave-search-mcp-server"),
                                               MCPServerSetting(name: "Notes", url: "https://notes.example.com/mcp", enabled: false)]
        for (listening, answers) in [(CaptionEngine.automatic, AssistantAnswerEngine.automatic), (.onDevice, .provider)] {
            model.preferences.assistant.listening = listening
            model.preferences.assistant.answers = answers
            let form = Form { AssistantSettings(model: model, assistant: model.assistant) }.formStyle(.grouped).frame(width: 592, height: 1750)
            try render(form, to: URL(fileURLWithPath: folder).appendingPathComponent("assistant-\(listening.rawValue)-\(answers.rawValue).png"))
        }
        typealias Line = MeetingAssistant.Line
        var lines = [Line(speaker: .them, text: "Thanks for joining. Let's go through the launch plan."),
                     Line(speaker: .you, text: "Sure, I have the latest timeline open."),
                     Line(speaker: .them, text: "Quick question. When is the Orion launch now?"),
                     Line(speaker: .you, text: "네, 잠깐만요. 확인해 볼게요")]
        for index in 0..<3 { lines[index].final = true }
        var answered = MeetingAssistant.Answer(question: "Quick question. When is the Orion launch now?", automatic: true)
        answered.text = "Orion now launches on November 12 [M1], moved from November 5 after the security review [M2]."
        answered.state = .done
        let slack = Moment(id: "m1", appName: "Slack", windowTitle: "#orion - Launch moved to November 12", text: "", kind: "screen")
        let notes = Moment(id: "m2", appName: "Notes", windowTitle: "Orion security review", text: "", kind: "screen")
        answered.sources = [("M1", slack), ("M2", notes)]
        var searching = MeetingAssistant.Answer(question: "Who owns the security review?", automatic: false)
        searching.state = .working("Searching the web for Orion security review owner")
        answered.pages = [("W1", WebSearchResult.Source(title: "Orion launch moves to November", url: "https://www.example.com/orion"))]
        model.assistant.preview(lines: lines, answers: [answered, searching], heardBy: [.you: "OpenAI", .them: "OpenAI"])
        let panel = AssistantView(model: model, assistant: model.assistant).frame(width: 380, height: 560)
        try render(panel, to: URL(fileURLWithPath: folder).appendingPathComponent("assistant-panel.png"))
        model.assistant.preview(lines: [], answers: [], heardBy: [:])
        try render(AssistantView(model: model, assistant: model.assistant).frame(width: 380, height: 560),
                   to: URL(fileURLWithPath: folder).appendingPathComponent("assistant-panel-empty.png"))
        model.assistant.stop()
        let editor = MCPServerEditor(server: MCPServerSetting(name: "Brave Search", command: "npx -y @brave/brave-search-mcp-server"), isNew: true, save: { _ in }, remove: {})
        try render(editor, to: URL(fileURLWithPath: folder).appendingPathComponent("assistant-mcp-editor.png"))
    }

    /// AI & Models with an API provider. The keychain is only asked whether keys exist, never read.
    @MainActor func testRenderAPIProviderSettingsWhenRequested() async throws {
        guard let folder = ProcessInfo.processInfo.environment["REPRISE_RENDER"] else { throw XCTSkip("Set REPRISE_RENDER to a folder to render previews.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let model = try AppModel(root: root, keys: testKeys, models: root.appendingPathComponent("Models"))
        model.provider = AIProviderConfiguration(provider: .anthropicAPI)
        let form = Form { AISettings(model: model) }.formStyle(.grouped).frame(width: 592, height: 1000)
        try render(form, to: URL(fileURLWithPath: folder).appendingPathComponent("ai-anthropic-api.png"))
    }

    /// The floating caption panel: shown while captions run, click-through, draggable only while moving.
    @MainActor func testCaptionPanelFollowsCaptionsWhenRequested() async throws {
        guard let folder = ProcessInfo.processInfo.environment["REPRISE_RENDER"] else { throw XCTSkip("Set REPRISE_RENDER to a folder to render previews.") }
        _ = NSApplication.shared
        let captions = LiveCaptions()
        captions.makeFeed = { _, _, _, _ in SilentFeed() }
        var saved: [[Double]] = []
        let controller = CaptionWindowController(captions: captions) { saved.append($0) }
        var style = CaptionPreferences()
        style.engine = .onDevice
        style.spoken = "sv-SE"
        captions.style = style
        captions.start(style, access: .chatGPT, codexPath: nil, keep: SpeechLanguages())
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? CaptionPanel }.first)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertEqual(panel.level, .statusBar)
        let bottom = panel.frame
        style.position = .top
        captions.style = style
        XCTAssertGreaterThan(panel.frame.minY, bottom.minY)
        captions.moving = true
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.canBecomeKey)
        captions.moving = false
        XCTAssertTrue(saved.isEmpty, "Done without dragging keeps the chosen position")
        captions.moving = true
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 40, y: panel.frame.minY - 60))
        captions.moving = false
        XCTAssertEqual(saved.count, 1)
        let content = try XCTUnwrap(panel.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("caption-panel.png"))
        captions.stop()
        XCTAssertFalse(panel.isVisible)
        withExtendedLifetime(controller) {}
    }

    @MainActor func testRenderMemoryOverlayControlsWhenRequested() async throws {
        guard let folder = ProcessInfo.processInfo.environment["REPRISE_RENDER"] else { throw XCTSkip("Set REPRISE_RENDER to a folder to render previews.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let model = try AppModel(root: root, keys: testKeys, models: root.appendingPathComponent("Models"))
        let overlay = ZStack { Color(white: 0.55); MemoryExplorerView(model: model, topInset: 51, cornerRadius: 18, menuBar: 39) }
            .frame(width: 1400, height: 900)
        try render(overlay, to: URL(fileURLWithPath: folder).appendingPathComponent("overlay-controls.png"))
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

/// Audio that never arrives.
private final class SilentFeed: LiveAudioFeed {
    func start() async throws {}
    func stop() {}
}
