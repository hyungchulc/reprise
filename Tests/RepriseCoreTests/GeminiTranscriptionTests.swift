import XCTest
@testable import RepriseCore

/// Gemini transcription: how its times and voices become segments, what Antigravity may do, and what the API is sent.
final class GeminiTranscriptionTests: XCTestCase {
    func testTimesAreRead() {
        XCTAssertEqual(GeminiTranscription.seconds("0:05"), 5)
        XCTAssertEqual(GeminiTranscription.seconds("12:34"), 754)
        XCTAssertEqual(GeminiTranscription.seconds("01:02:03"), 3_723)
        XCTAssertEqual(GeminiTranscription.seconds("[0:07]"), 7)
        XCTAssertEqual(GeminiTranscription.seconds("75.5"), 75.5)
        XCTAssertNil(GeminiTranscription.seconds("1:75"))
        XCTAssertNil(GeminiTranscription.seconds("soon"))
        XCTAssertNil(GeminiTranscription.seconds(""))
    }

    func testSegmentsKeepTheirOrderAndVoicesAreNumberedAsTheySpeak() {
        let lines = [GeminiTranscription.Line(start: 0, speaker: "Speaker 2", text: "안녕하세요."),
                     GeminiTranscription.Line(start: 6, speaker: "Speaker 1", text: "네, 좋습니다."),
                     GeminiTranscription.Line(start: 4, speaker: "Speaker 2", text: "Out of order"),
                     GeminiTranscription.Line(start: 900, speaker: "Speaker 1", text: "Past the end")]
        let segments = GeminiTranscription.segments(lines, offset: 1_800, duration: 20, speakers: true)
        XCTAssertEqual(segments.map(\.start), [1_800, 1_806, 1_806, 1_820])
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 2"])
        XCTAssertEqual(segments[0].end, 1_804.1, accuracy: 0.01, "ends after about the time its words take")
        XCTAssertEqual(segments[1].end, 1_810.8, accuracy: 0.01)
        XCTAssertEqual(segments[3].end, 1_820.3, accuracy: 0.01, "a line at the very end still lasts a moment")
        XCTAssertTrue(segments.allSatisfy(\.isValid))
        XCTAssertTrue(GeminiTranscription.segments(lines, offset: 0, duration: 20, speakers: false).allSatisfy { $0.speaker == nil })
    }

    func testAnswersAreReadAndAnUnreadableFileIsAFailure() throws {
        let read = try GeminiTranscription.lines(["segments": [["start": "0:03", "speaker": " Speaker 1 ", "text": " 시작할게요. "],
                                                               ["start": 9, "speaker": "", "text": "Numbers work too"],
                                                               ["start": "0:10", "speaker": "Speaker 2", "text": "  "]]])
        XCTAssertEqual(read, [GeminiTranscription.Line(start: 3, speaker: "Speaker 1", text: "시작할게요."),
                              GeminiTranscription.Line(start: 9, speaker: nil, text: "Numbers work too")])
        XCTAssertThrowsError(try GeminiTranscription.lines(["segments": [], "unreadable": true]))
        XCTAssertThrowsError(try GeminiTranscription.lines(["text": "no segments"]))
        let instructions = GeminiTranscription.instructions(speakers: true, language: "ko")
        XCTAssertTrue(instructions.contains("Korean"))
        XCTAssertTrue(instructions.contains("Speaker 1"))
        XCTAssertTrue(GeminiTranscription.instructions(speakers: false, language: nil).contains("Leave speaker empty"))
    }

    /// Antigravity may open the file it was given and nothing else.
    func testAntigravityMayOnlyReadTheFileItWasGiven() throws {
        func run(_ steps: [String], denied: Bool = false) -> String {
            let updates = steps.map { #"{"event":"step_update","step_update":{"step_type":"tool","tool_name":"\#($0)","state":"DONE"}}"# }
            let result = #"{"event":"result","result":{"status":"SUCCESS","denied_actions":\#(denied ? #"[{"action":"command"}]"# : "[]"),"structured_output":{"segments":[]}}}"#
            return (updates + [result]).joined(separator: "\n")
        }
        func parse(_ text: String, allowed: Set<String>) throws -> [String: Any] {
            try AIResponseParser.structured(Data(text.utf8), provider: .gemini, requestedModel: "gemini-x-flash-low", duration: 1, allowedTools: allowed).payload
        }
        XCTAssertNotNil(try parse(run(["view_file"]), allowed: ["view_file"])["segments"])
        XCTAssertThrowsError(try parse(run(["view_file"]), allowed: [])) { XCTAssertEqual($0 as? AIProviderError, .toolAttempt) }
        XCTAssertThrowsError(try parse(run(["view_file", "run_command"]), allowed: ["view_file"])) { XCTAssertEqual($0 as? AIProviderError, .toolAttempt) }
        XCTAssertThrowsError(try parse(run(["view_file"], denied: true), allowed: ["view_file"])) { XCTAssertEqual($0 as? AIProviderError, .toolAttempt) }
        XCTAssertEqual(GeminiTranscription.automaticModel([AIModelOption(id: "claude-opus-5-5-low", name: ""), AIModelOption(id: "gemini-9-flash-low", name: "")]),
                       "gemini-9-flash-low", "only Gemini hears audio")
    }

    func testTheAPIIsSentTheAudioInline() throws {
        let audio = Data([0xFF, 0xF1, 0x50, 0x80, 0x01])
        let request = try ProviderAPI.geminiAudioRequest(key: "made-up", model: "gemini-x-flash", system: "rules", audio: audio,
                                                         mimeType: "audio/aac", prompt: "Transcribe this recording.", schema: ["type": "object"], timeout: 60)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "made-up")
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-x-flash:generateContent")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let parts = try XCTUnwrap(((body["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(parts.first?["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/aac")
        XCTAssertEqual(inline["data"] as? String, audio.base64EncodedString())
        XCTAssertEqual(parts.last?["text"] as? String, "Transcribe this recording.")
        XCTAssertNotNil((body["generationConfig"] as? [String: Any])?["responseJsonSchema"])
        XCTAssertEqual(GeminiTranscription.lightThinking("gemini-9.1-flash")["thinkingLevel"] as? String, "low")
        XCTAssertEqual(GeminiTranscription.lightThinking("gemini-2.5-flash")["thinkingBudget"] as? Int, 0)
    }

    /// Sends a made-up key with a moment of audio; Google must refuse the key, not the request.
    func testGoogleRefusesOnlyTheKeyWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_API_ENDPOINTS"] == "1" else { throw XCTSkip("Set REPRISE_TEST_API_ENDPOINTS=1 to reach Google.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-gemini-\(UUID().uuidString).aac")
        try Data([0xFF, 0xF1, 0x50, 0x80, 0x01, 0x7F, 0xFC]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await GeminiTranscription.api(file, key: "made-up-gemini-key-for-reprise-tests", model: "gemini-2.5-flash", speakers: true, language: "ko", timeout: 30)
            XCTFail("A made-up key was accepted")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .apiFailed("\(APIKeyProvider.gemini.displayName) did not accept the API key. Check it in AI & Models."))
        }
    }
}
