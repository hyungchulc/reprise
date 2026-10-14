import AVFoundation
import XCTest
@testable import RepriseCore
@testable import Reprise

final class TranscriptionEngineTests: XCTestCase {
    func testSpeakersAreNumberedInSpeakingOrderAndRenamedEverywhere() {
        let segments = [TranscriptSegment(start: 0, end: 4, text: "Hello"), TranscriptSegment(start: 4.5, end: 8, text: "Hi there"),
                        TranscriptSegment(start: 8.2, end: 9, text: "Right"), TranscriptSegment(start: 30, end: 31, text: "Alone")]
        let turns = [SpeakerTurn(start: 0, end: 4.2, speaker: 7), SpeakerTurn(start: 4.2, end: 7.9, speaker: 3), SpeakerTurn(start: 7.9, end: 9.5, speaker: 3)]
        let labeled = SpeakerLabels.assign(turns, to: segments)
        XCTAssertEqual(labeled.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2", nil])
        XCTAssertEqual(SpeakerLabels.text(labeled), "Speaker 1: Hello\nSpeaker 2: Hi there\nRight\nAlone")
        let renamed = SpeakerLabels.rename("Speaker 2", to: "  Mina\n", in: labeled)
        XCTAssertEqual(renamed.map(\.speaker), ["Speaker 1", "Mina", "Mina", nil])
        XCTAssertEqual(SpeakerLabels.speakers(in: renamed), ["Speaker 1", "Mina"])
        XCTAssertEqual(SpeakerLabels.rename("Mina", to: "   ", in: renamed), renamed)
    }

    func testLongFollowUpThreadsKeepTheirEarlierQuestions() {
        let response = AIResponse(text: "Answer", citations: [], usage: UsageEntry(provider: "codex", model: ""))
        let turns = (1...9).map { MemorySearchTurn(question: "Question \($0)", response: response) }
        XCTAssertEqual(MemorySearchTurn.earlierQuestions(turns, limit: 4), (1...5).map { "Question \($0)" })
        XCTAssertEqual(MemorySearchTurn.context(turns, limit: 4).count, 4)
        XCTAssertTrue(MemorySearchTurn.earlierQuestions(turns, limit: 1).isEmpty, "Small budgets keep only the latest turn")
        XCTAssertNil(MemorySearchTurn.conversation(Array(turns.prefix(3)), limit: 4)["earlierQuestions"])
    }

    func testPiecesAreCutAtTheQuietestMoment() {
        var samples = [Float](repeating: 0.5, count: 10_000)
        for index in 6_000..<6_200 { samples[index] = 0 }
        let cut = RecordingPCM.quietest(samples, from: 5_000, to: 7_000, window: 100)
        XCTAssertTrue((6_000...6_200).contains(cut), "cut at \(cut)")
    }

    func testWhisperSoundMarksAreNotSpeech() {
        XCTAssertEqual(WhisperText.clean(" [Music] "), "")
        XCTAssertEqual(WhisperText.clean("(웃음)"), "")
        XCTAssertEqual(WhisperText.clean(" 회의를 시작합니다. "), "회의를 시작합니다.")
    }

    /// Pieces go to Gemini as AAC: an MP4 file for Antigravity, raw AAC for the API.
    func testGeminiPiecesAreWrittenAsCompressedAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-gemini-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.2) * 0.3) }
        for name in ["piece.m4a", "piece.aac"] {
            let url = folder.appendingPathComponent(name)
            try GeminiTranscriber.write(samples, sampleRate: 16_000, to: url)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(Double(file.length) / 16_000, 3, accuracy: 0.2, name)
        }
    }

    // MARK: Live engines, on request

    /// A short synthetic meeting of two voices through this Mac's Antigravity Google sign-in.
    @MainActor func testGeminiTranscribesAndLabelsSpeakersWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_GEMINI"] == "1" else { throw XCTSkip("Set REPRISE_TEST_GEMINI=1 to transcribe with Gemini through Antigravity.") }
        let (recorder, store, moment, root) = try await meeting(voices: [
            ("Yuna", "안녕하세요. 오늘 회의는 출시 일정에 대한 것입니다. 먼저 디자인 진행 상황을 들어볼게요."),
            ("Daniel", "Thanks. The design team rebuilt the search screen last week, and we will share it on Monday."),
            ("Yuna", "좋습니다. 그럼 개발 일정은 어떻게 되나요?"),
            ("Daniel", "The backend is done on Friday.")])
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        await recorder.transcribeSaved(moment, request: TranscriptionRequest(engine: .gemini, locales: ["ko-KR", "en-US"], speakerLabels: true))
        let saved = try await store.moment(id: moment.id)
        print("Gemini in \(String(format: "%.1f", Date().timeIntervalSince(start))) s:", saved?.transcriptSegments?.map { "\(String(format: "%.1f-%.1f", $0.start, $0.end)) \($0.speaker ?? "-") \($0.text)" } ?? [], saved?.transcriptionNote ?? "")
        XCTAssertNil(saved?.transcriptionNote, "Gemini fell back or warned")
        XCTAssertTrue(saved?.text.contains("회의") == true)
        XCTAssertEqual(SpeakerLabels.speakers(in: saved?.transcriptSegments ?? []).count, 2)
    }

    /// Sends a short synthetic meeting to OpenAI through this Mac's Codex ChatGPT sign-in.
    @MainActor func testOpenAITranscribesASavedMeetingWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_OPENAI"] == "1" else { throw XCTSkip("Set REPRISE_TEST_OPENAI=1 to transcribe with OpenAI.") }
        let (recorder, store, moment, root) = try await meeting(voices: [("Yuna", "오늘 회의를 시작하겠습니다. 다음 분기 출시 일정을 정리할게요.")])
        defer { try? FileManager.default.removeItem(at: root) }
        await recorder.transcribeSaved(moment, request: TranscriptionRequest(engine: .openAI, locales: ["ko-KR"]))
        let saved = try await store.moment(id: moment.id)
        print("OpenAI:", saved?.transcriptSegments?.map { "\(String(format: "%.1f-%.1f", $0.start, $0.end)) \($0.text)" } ?? [], saved?.transcriptionNote ?? "")
        XCTAssertNil(saved?.transcriptionNote, "OpenAI fell back or warned")
        XCTAssertTrue(saved?.text.contains("회의") == true)
    }

    /// Downloads Whisper base (about 150 MB) once into a temporary folder and transcribes with it.
    @MainActor func testWhisperDownloadsAndTranscribesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_WHISPER"] == "1" else { throw XCTSkip("Set REPRISE_TEST_WHISPER=1 to download and run Whisper.") }
        let models = LocalSpeechModels(directory: FileManager.default.temporaryDirectory.appendingPathComponent("reprise-test-models"))
        models.download("base")
        while true {
            if case .failed(let message) = models.state(of: "base") { XCTFail(message); return }
            if models.isReady("base") { break }
            try await Task.sleep(for: .seconds(1))
        }
        let (recorder, store, moment, root) = try await meeting(voices: [("Samantha", "Let's review the launch plan and the hiring budget for next quarter.")], models: models)
        defer { try? FileManager.default.removeItem(at: root) }
        await recorder.transcribeSaved(moment, request: TranscriptionRequest(engine: .whisperKit, locales: ["en-US"], whisperModel: "base"))
        let saved = try await store.moment(id: moment.id)
        print("Whisper:", saved?.transcriptSegments?.map { "\(String(format: "%.1f-%.1f", $0.start, $0.end)) \($0.text)" } ?? [], saved?.transcriptionNote ?? "")
        XCTAssertNil(saved?.transcriptionNote, "Whisper fell back or warned")
        XCTAssertTrue(saved?.text.lowercased().contains("launch") == true)
    }

    /// Two voices, told apart by the speaker model on this Mac.
    @MainActor func testSpeakersAreLabeledWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_SPEAKERS"] == "1" else { throw XCTSkip("Set REPRISE_TEST_SPEAKERS=1 to label speakers.") }
        let models = LocalSpeechModels(directory: FileManager.default.temporaryDirectory.appendingPathComponent("reprise-test-models"))
        models.downloadSpeakers()
        while models.speakers != .ready {
            if case .failed(let message) = models.speakers { XCTFail(message); return }
            try await Task.sleep(for: .seconds(1))
        }
        // Yuna is the only Korean voice macOS ships ready to speak, so the second voice speaks English.
        let (recorder, store, moment, root) = try await meeting(voices: [
            ("Yuna", "안녕하세요. 오늘 회의는 출시 일정에 대한 것입니다. 먼저 디자인 진행 상황을 들어볼게요."),
            ("Daniel", "Thanks. The design team rebuilt the search screen last week, and we will share it on Monday."),
            ("Yuna", "좋습니다. 그럼 개발 일정은 어떻게 되나요? 테스트 기간도 알려주세요."),
            ("Daniel", "The backend is done on Friday, and testing takes about two weeks after that.")], models: models)
        defer { try? FileManager.default.removeItem(at: root) }
        await recorder.transcribeSaved(moment, request: TranscriptionRequest(engine: .apple, locales: ["ko-KR", "en-US"], speakerLabels: true))
        let saved = try await store.moment(id: moment.id)
        print("Speakers:", saved?.text ?? "", saved?.transcriptionNote ?? "")
        XCTAssertGreaterThanOrEqual(SpeakerLabels.speakers(in: saved?.transcriptSegments ?? []).count, 2)
    }

    /// A sealed meeting recording of the given voices, one after another with a pause between.
    @MainActor private func meeting(voices: [(String, String)], models: LocalSpeechModels? = nil) async throws -> (MeetingRecorder, MomentStore, Moment, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-engine-\(UUID().uuidString)")
        let meetings = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let audio = meetings.appendingPathComponent("meeting.caf")
        var output: AVAudioFile?
        for (index, voice) in voices.enumerated() {
            let spoken = root.appendingPathComponent("part\(index).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice.0, "--data-format=BEI16@22050", "-o", spoken.path, voice.1 + " [[slnc 700]]"]
            try say.run(); say.waitUntilExit()
            let file = try AVAudioFile(forReading: spoken)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            if output == nil { output = try AVAudioFile(forWriting: audio, settings: file.processingFormat.settings) }
            try output?.write(from: buffer)
        }
        output = nil
        XCTAssertTrue(try testKeys.cipher.sealFile(at: audio))
        let store = try MomentStore(root: root, keys: testKeys)
        let moment = Moment(appName: "Meeting", windowTitle: "Engine test", videoPath: "meetings/meeting.caf", kind: "meeting")
        try await store.insert(moment)
        let recorder = MeetingRecorder(store: store, root: root, languages: SpeechLanguages(),
                                       speechModels: models ?? LocalSpeechModels(directory: root.appendingPathComponent("Models")))
        return (recorder, store, moment, root)
    }
}
