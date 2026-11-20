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
        let typed = MeetingAssistant.prompt(MeetingAssistant.Question(text: "When is the Orion launch?"),
                                            lines: [MeetingAssistant.Line(speaker: .you, text: "Let me check.")], answered: [])
        XCTAssertTrue(typed.contains("You: Let me check."))
        XCTAssertTrue(typed.contains("The user asks: When is the Orion launch?"))
        XCTAssertTrue(typed.hasSuffix(MeetingAssistant.length(MeetingAssistant.Question(text: "x"))))
        XCTAssertEqual(MeetingAssistant.keywords("Quick question: when is the Orion launch now?"), ["launch", "Orion"])
    }

    /// The others' question runs from the start of their turn to its end, and never takes in one already answered.
    func testQuestionIsTheirWholeTurnApartFromAnsweredOnes() throws {
        let start = Date()
        func line(_ speaker: MeetingAssistant.Speaker, _ text: String, at seconds: TimeInterval) -> MeetingAssistant.Line {
            MeetingAssistant.Line(speaker: speaker, text: text, final: true, time: start.addingTimeInterval(seconds), updated: start.addingTimeInterval(seconds + 1))
        }
        var lines = [line(.them, "Thanks for joining.", at: 0),
                     line(.you, "Happy to be here.", at: 3),
                     line(.them, "Quick question.", at: 6),
                     line(.them, "When is the Orion launch now?", at: 8),
                     line(.them, "The client keeps asking.", at: 10)]
        // On its own: their turn since the user's line, with the sentence after the question mark.
        let first = try XCTUnwrap(MeetingAssistant.question(in: lines, answered: [], automatic: true))
        XCTAssertEqual(first.text, "Quick question. When is the Orion launch now? The client keeps asking.")
        XCTAssertEqual(first.lines, lines[2...].map(\.id))
        // Once answered it does not answer itself again, and a click answers it again whole.
        var answered = Set(first.lines)
        XCTAssertNil(MeetingAssistant.question(in: lines, answered: answered, automatic: true))
        XCTAssertEqual(MeetingAssistant.question(in: lines, answered: answered, automatic: false)?.lines, first.lines)
        // What they go on to ask is a question of its own, with the answered one only as context.
        lines.append(line(.them, "And who signed off on the security review?", at: 13))
        let next = try XCTUnwrap(MeetingAssistant.question(in: lines, answered: answered, automatic: true))
        XCTAssertEqual(next.text, "And who signed off on the security review?")
        answered.formUnion(next.lines)
        let prompt = MeetingAssistant.prompt(next, lines: lines, answered: answered)
        XCTAssertTrue(prompt.contains("Them: When is the Orion launch now? (answered)"), prompt)
        XCTAssertTrue(prompt.contains("Question from Them to answer now:\nAnd who signed off on the security review?"), prompt)
        XCTAssertFalse(prompt.contains("security review? (answered)"), prompt)
        // A long pause starts a new turn; a request without a question mark waits for a click.
        lines.append(line(.them, "Tell me about the rollout plan.", at: 40))
        XCTAssertNil(MeetingAssistant.question(in: lines, answered: answered, automatic: true))
        XCTAssertEqual(MeetingAssistant.question(in: lines, answered: answered, automatic: false)?.text, "Tell me about the rollout plan.")
        // A provider reads 4 KB of transcript; what fits keeps the end of the question and the newest lines.
        let sentence = String(repeating: "출시 일정과 보안 검토 이야기를 길게 이어가는 중입니다. ", count: 4)
        var talk = (0..<40).map { line(.them, sentence + "\($0)", at: Double($0) * 2) }
        talk.append(line(.them, "그래서 출시는 언제예요?", at: 81))
        let asked = try XCTUnwrap(MeetingAssistant.question(in: talk, answered: [], automatic: false))
        let small = MeetingAssistant.prompt(asked, lines: talk, answered: [], limit: 3_800)
        XCTAssertLessThanOrEqual(small.utf8.count, 3_800)
        XCTAssertTrue(small.contains("그래서 출시는 언제예요?\n"), small)
        XCTAssertTrue(small.contains(" 35\n"), "the newest line before the question stays")
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
        try await store.insert(Moment(timestamp: Date().addingTimeInterval(-7_200), appName: "Mail", windowTitle: "Orion security review",
                                      text: "Priya Raman signed off on the Orion security review on Tuesday."))
        let assistant = MeetingAssistant(store: store, ai: AIClient())
        // Two questions with a pause between: each is answered on its own, once it is finished.
        assistant.setFeed(.them) { _, rate, deliver, _ in
            let first = (try? LiveCaptionTests.speech(voice: "Samantha", text: "Quick question. When is the Orion launch now?", rate: rate)) ?? []
            let second = (try? LiveCaptionTests.speech(voice: "Samantha", text: "And who signed off on the security review?", rate: rate)) ?? []
            return SpokenFeed(samples: first + [Float](repeating: 0, count: Int(rate * 6)) + second, rate: rate, deliver: deliver)
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
        while Date().timeIntervalSince(started) < 90 {
            if heardAt == nil, assistant.lastQuestion != nil { heardAt = Date().timeIntervalSince(started) }
            if let answer = assistant.answers.first {
                if case .working(let terms) = answer.state, searched.last != terms { searched.append(terms) }
                if firstText == nil, !answer.text.isEmpty { firstText = Date().timeIntervalSince(started) }
            }
            if assistant.answers.count == 2, assistant.answers.allSatisfy({ $0.state == .done }) { break }
            if let failed = assistant.answers.first(where: { if case .failed = $0.state { true } else { false } }) { XCTFail("\(failed.state)"); break }
            if let problem = assistant.problem { XCTFail(problem); break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Assistant heard \(assistant.lines.map { "\($0.speaker.rawValue): \($0.text)" }) first question at \(heardAt.map { String(format: "%.1f s", $0) } ?? "-"), first answer text at \(firstText.map { String(format: "%.1f s", $0) } ?? "-"), searched \(searched)")
        for answer in assistant.answers { print("Asked: \(answer.question)\n\(answer.text)\nsources \(answer.sources.map(\.label)) \(answer.sources.map(\.moment.appName))") }
        XCTAssertEqual(assistant.answers.count, 2)
        let launch = try XCTUnwrap(assistant.answers.first), review = try XCTUnwrap(assistant.answers.last)
        XCTAssertTrue(launch.automatic)
        XCTAssertTrue(launch.question.contains("Orion launch"), launch.question)
        XCTAssertFalse(launch.question.contains("signed"), launch.question)
        XCTAssertTrue(launch.text.contains("12"), launch.text)
        XCTAssertFalse(launch.text.lowercased().contains("checking"), "a lead-in before the search is no part of the answer: \(launch.text)")
        XCTAssertEqual(launch.sources.first?.moment.appName, "Slack")
        XCTAssertTrue(review.question.contains("signed off"), review.question)
        XCTAssertFalse(review.question.contains("launch"), review.question)
        XCTAssertTrue(review.text.contains("Priya"), review.text)
        // A click answers the last question again, in full, and only that question.
        assistant.answerLast()
        let clicked = Date()
        while Date().timeIntervalSince(clicked) < 60, assistant.answers.count < 3 || assistant.answers.last?.state != .done {
            if case .failed(let message) = assistant.answers.last?.state { XCTFail(message); break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let full = try XCTUnwrap(assistant.answers.last)
        print("Clicked, answered in \(String(format: "%.1f", Date().timeIntervalSince(clicked))) s. Asked: \(full.question)\n\(full.text)")
        XCTAssertEqual(assistant.answers.count, 3)
        XCTAssertFalse(full.automatic)
        XCTAssertEqual(full.question, review.question)
        XCTAssertTrue(full.text.contains("Priya"), full.text)
        XCTAssertFalse(full.text.lowercased().contains("let me"), full.text)
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
