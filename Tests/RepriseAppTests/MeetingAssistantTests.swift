import AVFoundation
import RepriseCore
import XCTest
@testable import Reprise
import RepriseMCPKit

final class MeetingAssistantTests: XCTestCase {
    func testQuestionsAndPromptsAreRecognized() {
        XCTAssertTrue(MeetingAssistant.isQuestion("When is the launch?"))
        XCTAssertTrue(MeetingAssistant.isQuestion("출시는 언제예요？ "))
        XCTAssertFalse(MeetingAssistant.isQuestion("The launch is in November."))
        let lines = [MeetingAssistant.Line(speaker: .them, text: "When is the Orion launch?"), MeetingAssistant.Line(speaker: .you, text: "Let me check.")]
        let prompt = MeetingAssistant.prompt(question: "When is the Orion launch?", lines: lines, fromThem: true)
        XCTAssertTrue(prompt.contains("Them: When is the Orion launch?"))
        XCTAssertTrue(prompt.contains("You: Let me check."))
        XCTAssertTrue(prompt.hasSuffix("Question from Them: When is the Orion launch?"))
        XCTAssertEqual(MeetingAssistant.keywords("Quick question: when is the Orion launch now?"), ["launch", "Orion"])
    }

    func testCitedMemoriesFollowTheAnswer() {
        let found = ["M1": Moment(id: "a", appName: "Slack"), "M2": Moment(id: "b", appName: "Mail")]
        let cited = MeetingAssistant.cited("It moved to November 12 [M2], see also [M2] and [M9].", in: found)
        XCTAssertEqual(cited.map(\.label), ["M2"])
    }

    func testMemorySearchLabelsExcerpts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        try await store.insert(Moment(appName: "Slack", windowTitle: "#orion", text: "The Orion launch moved to November 12 after the security review."))
        try await store.insert(Moment(appName: "Notes", windowTitle: "Groceries", text: "Milk, eggs, cinnamon."))
        let found = try await AssistantMemory.search(store, terms: ["Orion launch", "unrelated words"], firstLabel: 3)
        XCTAssertEqual(found.moments.map(\.label), ["M3"])
        let loose = try await AssistantMemory.search(store, terms: ["Orion launch date"])
        XCTAssertEqual(loose.moments.first?.moment.appName, "Slack", "words of a phrase that matches nowhere as a whole still find it")
        XCTAssertTrue(found.text.hasPrefix("[M3] "))
        XCTAssertTrue(found.text.contains("November 12"))
    }

    /// A question heard from Mac audio is answered on its own, from a memory, through OpenAI.
    @MainActor func testHeardQuestionIsAnsweredFromMemoryWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_OPENAI"] == "1" else { throw XCTSkip("Set REPRISE_TEST_OPENAI=1 to answer with OpenAI.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        try await store.insert(Moment(timestamp: Date().addingTimeInterval(-86_400), appName: "Slack", windowTitle: "#orion",
                                      text: "Heads up: the Orion launch moved to November 12 after the security review."))
        let assistant = MeetingAssistant(store: store, ai: AIClient())
        assistant.setFeed(.them) { _, rate, deliver, _ in
            SpokenFeed(samples: (try? LiveCaptionTests.speech(voice: "Samantha", text: "Quick question. When is the Orion launch now?", rate: rate)) ?? [],
                       rate: rate, deliver: deliver)
        }
        assistant.setFeed(.you) { _, rate, deliver, _ in SpokenFeed(samples: [], rate: rate, deliver: deliver) }
        var preferences = AssistantPreferences()
        preferences.listening = .openAI
        preferences.answers = .openAI
        preferences.webSearch = false
        let started = Date()
        assistant.start(preferences, meetingLanguages: [], access: .chatGPT, codexPath: nil, provider: { AIProviderConfiguration() }, languages: SpeechLanguages())
        defer { assistant.stop() }
        var firstText: TimeInterval?, heardAt: TimeInterval?
        var searched: [String] = []
        while Date().timeIntervalSince(started) < 60 {
            if heardAt == nil, assistant.lastQuestion != nil { heardAt = Date().timeIntervalSince(started) }
            if let answer = assistant.answers.first {
                if case .working(let terms) = answer.state, searched.last != terms { searched.append(terms) }
                if firstText == nil, !answer.text.isEmpty { firstText = Date().timeIntervalSince(started) }
                if answer.state == .done { break }
                if case .failed(let message) = answer.state { XCTFail(message); break }
            }
            if let problem = assistant.problem { XCTFail(problem); break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let answer = try XCTUnwrap(assistant.answers.first)
        print("Assistant heard \(assistant.lines.map { "\($0.speaker.rawValue): \($0.text)" }) question at \(heardAt.map { String(format: "%.1f s", $0) } ?? "-"), answer text at \(firstText.map { String(format: "%.1f s", $0) } ?? "-"), searched \(searched): \(answer.text) sources \(answer.sources.map(\.label))")
        XCTAssertTrue(answer.automatic)
        XCTAssertTrue(answer.text.contains("12"), answer.text)
        XCTAssertEqual(answer.sources.first?.moment.appName, "Slack")
    }
}

extension MeetingAssistantTests {
    /// A typed question about the public world is answered from the web through a CLI signed in on this Mac.
    @MainActor func testTypedQuestionIsAnsweredFromTheWebWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_OPENAI"] == "1", let route = ProcessInfo.processInfo.environment["REPRISE_TEST_WEB"].flatMap(WebSearchRoute.init(rawValue:)) else {
            throw XCTSkip("Set REPRISE_TEST_OPENAI=1 and REPRISE_TEST_WEB=codex or claude to answer from the web.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = MeetingAssistant(store: try MomentStore(root: root, keys: testKeys), ai: AIClient())
        for side in [MeetingAssistant.Speaker.you, .them] {
            assistant.setFeed(side) { _, rate, deliver, _ in SpokenFeed(samples: [], rate: rate, deliver: deliver) }
        }
        var preferences = AssistantPreferences()
        preferences.listening = .openAI
        preferences.answers = .openAI
        preferences.webRoute = route
        assistant.start(preferences, meetingLanguages: [], access: .chatGPT, codexPath: nil, provider: { AIProviderConfiguration() }, languages: SpeechLanguages())
        defer { assistant.stop() }
        assistant.draft = "What is the latest stable version of the Swift programming language?"
        let started = Date()
        assistant.askDraft()
        var activity: [String] = []
        while Date().timeIntervalSince(started) < 120 {
            if let answer = assistant.answers.first {
                if case .working(let what) = answer.state, activity.last != what { activity.append(what) }
                if answer.state == .done { break }
                if case .failed(let message) = answer.state { XCTFail(message); break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let answer = try XCTUnwrap(assistant.answers.first)
        print("Web answer in \(String(format: "%.1f", Date().timeIntervalSince(started))) s after \(activity): \(answer.text) pages \(answer.pages.map { "\($0.label) \($0.page.url)" })")
        XCTAssertTrue(activity.contains { $0.hasPrefix("Searching the web") }, "\(activity)")
        XCTAssertFalse(answer.pages.isEmpty)
    }
}

extension MeetingAssistantTests {
    /// A one-tool MCP server in Python: initialize, list and call, over stdio.
    static let codeServer = #"""
    import json, sys
    for line in sys.stdin:
        message = json.loads(line)
        method, ident = message.get("method"), message.get("id")
        if ident is None:
            continue
        if method == "initialize":
            result = {"protocolVersion": message["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "codes", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "project_code", "description": "Returns the code word of a project by name.",
                                 "inputSchema": {"type": "object", "properties": {"project": {"type": "string"}}, "required": ["project"]},
                                 "annotations": {"readOnlyHint": True}}]}
        elif method == "tools/call":
            project = message["params"].get("arguments", {}).get("project", "")
            result = {"content": [{"type": "text", "text": "The code word of %s is PINEAPPLE-42." % project}]}
        else:
            result = {}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}) + "\n")
        sys.stdout.flush()
    """#

    /// A typed question is answered with a tool from the person's own MCP server, through OpenAI.
    @MainActor func testTypedQuestionUsesAnMCPToolWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_OPENAI"] == "1" else { throw XCTSkip("Set REPRISE_TEST_OPENAI=1 to answer with OpenAI.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codes.py")
        try Self.codeServer.write(to: script, atomically: true, encoding: .utf8)
        let assistant = MeetingAssistant(store: try MomentStore(root: root, keys: testKeys), ai: AIClient())
        for side in [MeetingAssistant.Speaker.you, .them] {
            assistant.setFeed(side) { _, rate, deliver, _ in SpokenFeed(samples: [], rate: rate, deliver: deliver) }
        }
        var preferences = AssistantPreferences()
        preferences.listening = .openAI
        preferences.answers = .openAI
        preferences.webSearch = false
        preferences.servers = [MCPServerSetting(name: "Codes", command: "/usr/bin/python3 -u '\(script.path)'")]
        assistant.start(preferences, meetingLanguages: [], access: .chatGPT, codexPath: nil, provider: { AIProviderConfiguration() }, languages: SpeechLanguages())
        defer { assistant.stop() }
        let started = Date()
        while Date().timeIntervalSince(started) < 30, assistant.notice?.contains("MCP") != true {
            if let problem = assistant.problem { XCTFail(problem); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(assistant.notice, "1 MCP tool ready")
        assistant.draft = "What is the code word of project Orion?"
        assistant.askDraft()
        var activity: [String] = []
        while Date().timeIntervalSince(started) < 90 {
            if let answer = assistant.answers.first {
                if case .working(let what) = answer.state, activity.last != what { activity.append(what) }
                if answer.state == .done { break }
                if case .failed(let message) = answer.state { XCTFail(message); break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let answer = try XCTUnwrap(assistant.answers.first)
        print("MCP answer after \(activity): \(answer.text)")
        XCTAssertTrue(activity.contains("Using project_code from Codes"), "\(activity)")
        XCTAssertTrue(answer.text.contains("PINEAPPLE-42"), answer.text)
    }
}

/// A recording played in real time, then silence.
final class SpokenFeed: LiveAudioFeed, @unchecked Sendable {
    private let samples: [Float]
    private let format: AVAudioFormat
    private let deliver: (AVAudioPCMBuffer) -> Void
    private var task: Task<Void, Never>?

    init(samples: [Float], rate: Double, deliver: @escaping (AVAudioPCMBuffer) -> Void) {
        self.samples = samples
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        self.deliver = deliver
    }

    func start() async throws {
        let samples = samples, format = format, deliver = deliver
        task = Task.detached {
            let frame = Int(format.sampleRate / 10)
            var position = 0
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame)), let channel = buffer.floatChannelData?[0] else { return }
                buffer.frameLength = AVAudioFrameCount(frame)
                for index in 0..<frame { channel[index] = position + index < samples.count ? samples[position + index] : 0 }
                position += frame
                deliver(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() { task?.cancel() }
}
