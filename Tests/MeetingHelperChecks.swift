// Standalone checks, compiled with the two helper sources. No app or TCC APIs run.
// swiftc Sources/Reprise/{MeetingDetector,PermissionCenter}.swift Tests/MeetingHelperChecks.swift -o /tmp/reprise-helper-checks
import Foundation

@main
struct MeetingHelperChecks {
    @MainActor
    static func main() {
        let cases: [(String, String, Bool)] = [
            ("us.zoom.xos", "Zoom Meeting", true),
            ("us.zoom.xos", "Planning - Zoom Meeting", true),
            ("us.zoom.xos", "Zoom Webinar", true),
            ("us.zoom.xos", "Zoom Workplace", false),
            ("us.zoom.xos", "Home | Zoom Meeting", false),
            ("us.zoom.xos", "Zoom Meeting - Home", false),
            ("us.zoom.xos", "Zoom Meeting - Idle", false),
            ("us.zoom.xos", "Zoom Meeting - Not in a meeting", false),
            ("us.zoom.xos", "Zoom Meeting - Waiting for host", false),
            ("us.zoom.xos", "Zoom Meeting - Lobby", false),
            ("us.zoom.xos", "Zoom Meeting - Meeting ended", false),
            ("us.zoom.xos", "", false),
            ("com.microsoft.teams2", "Meeting: Planning", true),
            ("com.microsoft.teams2", "Planning | Meeting", true),
            ("com.microsoft.teams2", "Call with Alex", true),
            ("com.microsoft.teams2", "Microsoft Teams", false),
            ("com.microsoft.teams2", "Meeting notes | Microsoft Teams", false),
            ("com.microsoft.teams2", "Calendar | Microsoft Teams", false),
            ("com.microsoft.teams2", "Meeting: Ready to join", false),
            ("com.cisco.webexmeetingsapp", "Webex Meeting", true),
            ("com.cisco.webexmeetingsapp", "Webex", false),
            ("com.google.Chrome", "Meet - abc-defg-hij", true),
            ("com.apple.Safari", "Planning | Google Meet", true),
            ("com.google.Chrome", "Meet - abc-defg-hij - Waiting room", false),
            ("com.google.Chrome", "Google Meet", false),
            ("com.google.Chrome", "Join a meeting | Google Meet", false),
            ("com.google.Chrome", "https://meet.google.com/abc-defg-hij", true),
            ("com.google.Chrome", "https://example.com/zoom-meeting", false),
            ("com.apple.mail", "Zoom Meeting", false)
        ]
        for (bundleID, title, expected) in cases {
            let window = MeetingWindowMetadata(id: "1:2", title: title, appName: "Fixture", bundleID: bundleID)
            precondition((MeetingWindowRules.classify(window) != nil) == expected, "Unexpected classification: \(bundleID) / \(title)")
        }
        let urls: [(String, Bool)] = [
            ("https://meet.google.com/abc-defg-hij", true),
            ("https://meet.google.com/landing", false),
            ("https://meet.google.com.evil.test/abc-defg-hij", false),
            ("https://zoom.us/j/123456789?pwd=fixture", true),
            ("https://company.zoom.us/wc/12345678901/join", true),
            ("https://zoom.us/signin", false),
            ("https://notzoom.us/j/123456789", false),
            ("https://zoom.us.evil.test/j/123456789", false),
            ("https://teams.microsoft.com/l/meetup-join/fixture", true),
            ("https://teams.microsoft.com/v2", false),
            ("https://company.webex.com/meet/fixture", true),
            ("https://company.webex.com/", false),
            ("file://meet.google.com/abc-defg-hij", false)
        ]
        for (text, expected) in urls {
            precondition(MeetingWindowRules.isMeetingURL(URL(string: text)!) == expected, "Unexpected URL: \(text)")
        }
        let meeting = MeetingWindowMetadata(id: "1:2", title: "Zoom Meeting", appName: "Zoom", bundleID: "us.zoom.xos")
        var scans = 0
        let detector = MeetingDetector(snapshot: { scans += 1; return [meeting] })
        precondition(!detector.enabled && detector.candidate == nil && scans == 0)
        detector.start()
        precondition(detector.enabled && detector.candidate?.appName == "Zoom" && scans == 1)
        detector.start()
        precondition(scans == 1)
        detector.dismiss()
        precondition(detector.candidate == nil)
        detector.stop()
        precondition(!detector.enabled && detector.candidate == nil)
        precondition(PermissionCenter.Kind.allCases.count == 3)
        print("Passed \(cases.count) title and \(urls.count) URL fixtures, plus injected detector lifecycle checks.")
    }
}
