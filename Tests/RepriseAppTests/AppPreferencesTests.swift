import XCTest
@testable import Reprise

final class AppPreferencesTests: XCTestCase {
    func testPreferencesFromEarlierVersionsKeepValuesAndGainLanguageList() throws {
        // Saved by 0.4: one transcription language and no later keys.
        let saved = #"{"speechLocale":"en_US","accentRed":0,"includeSystemAudio":true,"iconPlacement":"menuBar","transcribeMeetings":true,"accentGreen":0.55,"darkMode":true,"accentBlue":0.55,"followSystemAppearance":false,"animateSearch":true,"textSize":15,"startRecordingOnLaunch":true,"followSystemAccent":true,"showOnLaunch":false,"detectMeetings":true}"#
        let restored = try JSONDecoder().decode(AppPreferences.self, from: Data(saved.utf8))
        XCTAssertEqual(restored.iconPlacement, .menuBar)
        XCTAssertTrue(restored.darkMode)
        XCTAssertEqual(restored.textSize, 15)
        XCTAssertFalse(restored.showOnLaunch)
        XCTAssertTrue(restored.startRecordingOnLaunch)
        XCTAssertEqual(restored.speechLocales.first, "en-US")
        XCTAssertEqual(restored.pauseReminders, true)
        var changed = restored
        changed.speechLocales = ["ko-KR", "en-US"]
        XCTAssertEqual(changed.speechLocale, "ko-KR", "Earlier versions read the first language")
    }
}
