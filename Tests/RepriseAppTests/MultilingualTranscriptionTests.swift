import AVFoundation
import XCTest
@testable import RepriseCore
@testable import Reprise

final class MultilingualTranscriptionTests: XCTestCase {
    /// Uses the Mac's speech models and may download them, so it runs only on request.
    @MainActor func testMixedKoreanEnglishMeetingKeepsBothLanguagesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_SPEECH"] == "1" else { throw XCTSkip("Set REPRISE_TEST_SPEECH=1 to transcribe with on-device speech models.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-speech-\(UUID().uuidString)")
        let meetings = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parts = [("Yuna", "안녕하세요. 오늘 회의를 시작하겠습니다. 먼저 예산 문제를 이야기해 볼게요."),
                     ("Samantha", "Thanks. Let's review the launch timeline and the hiring plan next.")]
        let audio = meetings.appendingPathComponent("mixed.caf")
        var output: AVAudioFile?
        for (index, part) in parts.enumerated() {
            let spoken = root.appendingPathComponent("part\(index).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", part.0, "--data-format=BEI16@22050", "-o", spoken.path, part.1]
            try say.run(); say.waitUntilExit()
            let file = try AVAudioFile(forReading: spoken)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            if output == nil { output = try AVAudioFile(forWriting: audio, settings: file.processingFormat.settings) }
            try output?.write(from: buffer)
        }
        output = nil
        let store = try MomentStore(root: root)
        let moment = Moment(appName: "Meeting", windowTitle: "Mixed", videoPath: "meetings/mixed.caf", kind: "meeting")
        try await store.insert(moment)
        let recorder = MeetingRecorder(store: store, root: root, languages: SpeechLanguages())
        await recorder.transcribeSaved(moment, locales: ["ko-KR", "en-US"])
        let saved = try await store.moment(id: moment.id)
        let segments = saved?.transcriptSegments ?? []
        print("Transcript:", segments.map { "[\($0.locale ?? "?") \(String(format: "%.1f-%.1f", $0.start, $0.end))] \($0.text)" }.joined(separator: "\n"))
        XCTAssertNil(recorder.lastError)
        XCTAssertEqual(Set(segments.compactMap(\.locale)), ["ko-KR", "en-US"])
        XCTAssertTrue(saved?.text.contains("회의") == true)
        XCTAssertTrue(saved?.text.localizedCaseInsensitiveContains("timeline") == true)
    }
}
