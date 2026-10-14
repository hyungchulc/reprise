import XCTest
@testable import RepriseCore

/// OpenAI speaker finding: what is uploaded, how turns are read, and which clips carry voices on.
final class OpenAIDiarizationTests: XCTestCase {
    func testTheUploadAsksForSpeakersAndCarriesKnownVoices() throws {
        let request = OpenAIDiarization.request(Data([1, 2, 3]), filename: "recording.m4a", mimeType: "audio/mp4", bearer: "made-up", language: "ko",
                                                references: [.init(name: "Speaker 1", wav: Data([9]))], timeout: 60)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer made-up")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        for part in ["name=\"model\"\r\n\r\ngpt-4o-transcribe-diarize", "name=\"response_format\"\r\n\r\ndiarized_json",
                     "name=\"chunking_strategy\"\r\n\r\nauto", "name=\"language\"\r\n\r\nko", "name=\"known_speaker_names[]\"\r\n\r\nSpeaker 1",
                     "name=\"known_speaker_references[]\"\r\n\r\ndata:audio/wav;base64,CQ==", "filename=\"recording.m4a\"\r\nContent-Type: audio/mp4"] {
            XCTAssertTrue(body.contains(part), part)
        }
    }

    func testTurnsAreReadAndEachVoiceGivesOneClip() {
        let turns = OpenAIDiarization.turns(from: ["segments": [
            ["speaker": "A", "start": 0.0, "end": 1.0, "text": "1번 안건입니다."],
            ["speaker": "A", "start": 1.5, "end": 3.3, "text": "진행 상황을 말씀해 주세요."],
            ["speaker": "B", "start": 4.4, "end": 19.0, "text": "길게 말합니다."],
            ["speaker": "A", "start": 20.0, "end": 21.5, "text": "좋아요."],
            ["speaker": "C", "start": 24.0, "end": 25.0, "text": "네."],
            ["speaker": "", "start": 26, "end": 27, "text": "no speaker"],
            ["speaker": "A", "start": 30, "end": 29, "text": "backwards"]]])
        XCTAssertEqual(turns.map(\.speaker), ["A", "A", "B", "A", "C"])
        let spans = OpenAIDiarization.referenceSpans(turns)
        XCTAssertEqual(spans.map(\.speaker), ["A", "B"], "C spoke under two seconds")
        XCTAssertEqual(spans[0].start, 0); XCTAssertEqual(spans[0].end, 3.3, "short turns across a brief pause count as one stretch")
        XCTAssertEqual(spans[1].end, 14.4, accuracy: 0.001, "clips stop at ten seconds")
        let wav = OpenAIDiarization.wav([0, 0.5, -0.5, 1], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }
}
