import AVFoundation
import RepriseCore
import XCTest
@testable import Reprise

final class LiveCaptionTests: XCTestCase {
    func testCaptionLinesWrapAtWordsAndTreatHangulAsWide() {
        let sentence = "The quick brown fox jumps over the lazy dog"
        let lines = CaptionLayout.wrap(sentence, width: 200, size: 20)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined(separator: " "), sentence)
        XCTAssertGreaterThan(CaptionLayout.wrap(String(repeating: "가", count: 15), width: 200, size: 20).count, 1)
        XCTAssertEqual(CaptionLayout.wrap(String(repeating: "a", count: 15), width: 200, size: 20).count, 1)
    }

    func testCaptionsTranslateUnlessTheyStayInTheSpokenLanguage() {
        var preferences = CaptionPreferences()
        preferences.target = "ko"
        preferences.spoken = "sv-SE"
        XCTAssertEqual(preferences.translationTarget, "ko")
        XCTAssertTrue(LiveCaptions.openAISession(preferences).translation)
        preferences.target = "sv"
        XCTAssertNil(preferences.translationTarget)
        preferences.target = ""
        let (session, translation) = LiveCaptions.openAISession(preferences)
        XCTAssertFalse(translation)
        let input = (session["audio"] as? [String: Any])?["input"] as? [String: Any]
        XCTAssertEqual((input?["transcription"] as? [String: Any])?["language"] as? String, "sv")
    }

    func testCaptionSettingsFromAnEarlierVersionKeepTheirDefaults() throws {
        let decoded = try JSONDecoder().decode(CaptionPreferences.self, from: Data(#"{"textSize": 40, "engine": "removed"}"#.utf8))
        XCTAssertEqual(decoded.textSize, 40)
        XCTAssertEqual(decoded.engine, .automatic)
        XCTAssertEqual(decoded.lines, 2)
    }

    /// Streams synthetic Swedish speech to OpenAI as live captions do, translated and as spoken.
    @MainActor func testOpenAICaptionsStreamWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_OPENAI"] == "1" else { throw XCTSkip("Set REPRISE_TEST_OPENAI=1 to caption with OpenAI.") }
        let audio = try Self.speech(voice: "Alva", text: "Hej och välkommen. I dag pratar vi om hur man bakar kanelbullar hemma.")
        let credential = try await OpenAICredential.resolve(.chatGPT)
        for target in ["ko", ""] {
            var preferences = CaptionPreferences()
            preferences.target = target
            preferences.spoken = "sv-SE"
            preferences.showOriginal = true
            let (session, translation) = LiveCaptions.openAISession(preferences)
            let secret = try await OpenAIRealtime.clientSecret(credential, session: session, translation: translation)
            let socket = OpenAIRealtime.connect(secret: secret, translation: translation)
            let append = translation ? "session.input_audio_buffer.append" : "input_audio_buffer.append"
            var text = "", spoken = "", pieces = 0, finals = 0
            var firstText: TimeInterval?
            let started = Date()
            var sender: Task<Void, Never>?
            for try await event in socket.events {
                switch LiveCaptions.openAIEvent(event) {
                case .ready:
                    // Twice real time in 100 ms frames, then silence, then a few seconds for the last words.
                    sender = Task.detached {
                        let frame = 2_400
                        for start in stride(from: 0, to: audio.count, by: frame) {
                            let chunk = OpenAIRealtime.pcm16(audio[start..<min(start + frame, audio.count)])
                            try? await socket.send(["type": append, "audio": chunk.base64EncodedString()])
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        // Live audio keeps arriving, silent or not, so the last words come out.
                        let silence = OpenAIRealtime.pcm16([Float](repeating: 0, count: frame))
                        for _ in 0..<100 {
                            try? await socket.send(["type": append, "audio": silence.base64EncodedString()])
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        socket.close()
                    }
                case .caption(let delta), .partial(let delta):
                    text += delta; pieces += 1
                    firstText = firstText ?? Date().timeIntervalSince(started)
                case .spoken(let delta): spoken += delta
                case .final(let transcript):
                    finals += 1
                    if pieces == 0 { text += transcript }
                case .failure(let message, let code): XCTFail("\(code): \(message)"); socket.close()
                case .other: break
                }
            }
            sender?.cancel()
            print("Captions \(translation ? "into \(target)" : "as spoken"): pieces \(pieces), finals \(finals), first text after \(firstText.map { String(format: "%.1f s", $0) } ?? "none"): \(text) | spoken: \(spoken)")
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
            if translation { XCTAssertNotNil(text.range(of: "\\p{Script=Hangul}", options: .regularExpression)) }
            else { XCTAssertTrue(text.lowercased().contains("välkommen") || text.lowercased().contains("kanelbullar")) }
        }
    }

    /// Live captions end to end, with a recording in place of Mac audio: on this Mac, and with OpenAI when requested.
    @MainActor func testCaptionsTranslateSpeechEndToEndWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_CAPTIONS"] == "1" else { throw XCTSkip("Set REPRISE_TEST_CAPTIONS=1 to run live captions.") }
        var engines: [CaptionEngine] = []
        if #available(macOS 26, *) { engines.append(.onDevice) }
        if ProcessInfo.processInfo.environment["REPRISE_TEST_OPENAI"] == "1" { engines.append(.openAI) }
        for engine in engines {
            let captions = LiveCaptions()
            captions.makeFeed = { _, rate, deliver, _ in
                RecordingFeed(samples: (try? Self.speech(voice: "Alva", text: "Hej och välkommen. I dag pratar vi om hur man bakar kanelbullar hemma. Först värmer vi mjölken.", rate: rate)) ?? [],
                              rate: rate, deliver: deliver)
            }
            var preferences = CaptionPreferences()
            preferences.engine = engine
            preferences.spoken = "sv-SE"
            preferences.target = "ko"
            preferences.showOriginal = true
            captions.start(preferences, access: .chatGPT, codexPath: nil, keep: SpeechLanguages())
            let started = Date()
            var firstKorean: TimeInterval?
            var last = "", spoken = ""
            while Date().timeIntervalSince(started) < 60 {
                if !captions.text.isEmpty { last = captions.text; spoken = captions.spokenText }
                if firstKorean == nil, last.range(of: "\\p{Script=Hangul}", options: .regularExpression) != nil { firstKorean = Date().timeIntervalSince(started) }
                if let problem = captions.problem { XCTFail("\(engine): \(problem)"); break }
                if let firstKorean, Date().timeIntervalSince(started) > firstKorean + 10 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            captions.stop()
            print("Captions \(engine), first Korean after \(firstKorean.map { String(format: "%.1f s", $0) } ?? "none"): \(last.debugDescription) | spoken: \(spoken.debugDescription)")
            XCTAssertNotNil(firstKorean, "\(engine) wrote no Korean captions")
        }
    }

    /// Speech from a macOS voice as mono samples.
    static func speech(voice: String, text: String, rate: Double = 24_000) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-caption-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "--file-format=WAVE", "--data-format=LEI16@\(Int(rate))", "-o", file.path, text]
        try say.run(); say.waitUntilExit()
        let audio = try AVAudioFile(forReading: file)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
}

/// A recording played as live audio in real time, then silence, as Mac audio would arrive.
private final class RecordingFeed: LiveAudioFeed, @unchecked Sendable {
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
