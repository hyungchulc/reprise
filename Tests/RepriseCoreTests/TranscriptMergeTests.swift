import XCTest
@testable import RepriseCore

final class TranscriptMergeTests: XCTestCase {
    private func words(_ text: String, from start: Double, step: Double = 0.4, confidence: Double) -> [RecognizedSpeech] {
        text.split(separator: " ").enumerated().flatMap { index, word -> [RecognizedSpeech] in
            let begin = start + Double(index) * step
            let timed = RecognizedSpeech(text: String(word), start: begin, end: begin + step * 0.9, confidence: confidence)
            return index == 0 ? [timed] : [RecognizedSpeech(text: " "), timed]
        }
    }

    func testMixedMeetingKeepsEachSpeakersLanguage() {
        // Korean speech at 0-3 s, English at 4-7 s; each recognizer guesses poorly at the other language.
        let korean = words("안녕하세요 오늘 회의를 시작합니다", from: 0, step: 0.7, confidence: 0.92)
            + [RecognizedSpeech(text: " ")] + words("렛츠 비긴 위드", from: 4, step: 1, confidence: 0.25)
        let english = words("on young ha say", from: 0, step: 0.7, confidence: 0.2)
            + [RecognizedSpeech(text: " ")] + words("Let's begin with the roadmap.", from: 4, step: 0.6, confidence: 0.95)
        let segments = TranscriptMerge.segments([(locale: "ko-KR", speech: korean), (locale: "en-US", speech: english)])
        XCTAssertEqual(segments.map(\.locale), ["ko-KR", "en-US"])
        XCTAssertEqual(segments.map(\.text), ["안녕하세요 오늘 회의를 시작합니다", "Let's begin with the roadmap."])
        XCTAssertTrue(segments.allSatisfy(\.isValid))
        XCTAssertLessThanOrEqual(segments[0].end, segments[1].start)
    }

    func testStrayPunctuationAcrossTheOtherLanguageDoesNotHideWords() {
        // Observed from SpeechTranscriber on a Korean-then-English recording.
        let korean = [RecognizedSpeech(text: "안녕하세요.", start: 0, end: 0.78, confidence: 0.9),
                      RecognizedSpeech(text: " 예산을", start: 0.78, end: 2.5, confidence: 0.95),
                      RecognizedSpeech(text: " 이야기해", start: 2.5, end: 4.92, confidence: 0.97),
                      RecognizedSpeech(text: " 볼게요.", start: 4.92, end: 5.46, confidence: 0.89),
                      RecognizedSpeech(text: " .", start: 5.46, end: 9.97, confidence: 0.51)]
        let english = [RecognizedSpeech(text: ",", start: 0, end: 1.08, confidence: 0.03),
                       RecognizedSpeech(text: " ,", start: 1.08, end: 5.88, confidence: 0.02),
                       RecognizedSpeech(text: " thanks.", start: 5.88, end: 6.48, confidence: 0.48),
                       RecognizedSpeech(text: " Let's", start: 6.54, end: 7.02, confidence: 0.8),
                       RecognizedSpeech(text: " review.", start: 7.02, end: 7.5, confidence: 0.97)]
        let segments = TranscriptMerge.segments([(locale: "ko-KR", speech: korean), (locale: "en-US", speech: english)])
        XCTAssertEqual(segments.map(\.text), ["안녕하세요. 예산을 이야기해 볼게요.", "thanks. Let's review."])
        XCTAssertEqual(segments.last?.start, 5.88)
    }

    func testSingleLanguageKeepsAllSpeechAndBreaksAtLongPauses() {
        let speech = words("First topic is budget.", from: 0, confidence: 0.9) + words("Second topic is hiring", from: 40, confidence: 0)
        let segments = TranscriptMerge.segments([(locale: "en-US", speech: speech)])
        XCTAssertEqual(segments.map(\.text), ["First topic is budget.", "Second topic is hiring"])
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.start, 40)
    }

    func testLanguagesWithoutSpacesJoinDirectly() {
        XCTAssertEqual(TranscriptMerge.joiner(for: "ja-JP"), "")
        XCTAssertEqual(TranscriptMerge.joiner(for: "ko-KR"), " ")
    }

    func testChoicesResolveToRecognizerLocales() {
        let supported = ["en-US", "en-GB", "ko-KR", "ja-JP", "zh-CN"]
        XCTAssertEqual(SpeechLanguageSelection.resolve("ko-US", supported: supported), "ko-KR")
        XCTAssertEqual(SpeechLanguageSelection.resolve("en_GB", supported: supported), "en-GB")
        XCTAssertEqual(SpeechLanguageSelection.resolve("en", supported: supported), "en-US")
        XCTAssertNil(SpeechLanguageSelection.resolve("sv-SE", supported: supported))
        XCTAssertEqual(SpeechLanguageSelection.defaults(preferred: ["en-US", "ko-US", "en-GB"], current: Locale(identifier: "en_US")), ["en-US", "ko-US"])
    }
}
