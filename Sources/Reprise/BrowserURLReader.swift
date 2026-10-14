import AppKit
import Carbon
import RepriseCore

/// Reads the front tab's address in Safari and Chromium browsers over Apple Events, only while that
/// browser is in front. macOS asks once per browser; the question is asked off the main thread and
/// that capture goes ahead without an address. A refusal is respected until Reprise restarts.
@MainActor
final class BrowserURLReader {
    private enum Family { case safari, chromium }
    private static let browsers: [String: Family] = [
        "com.apple.Safari": .safari, "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium, "com.google.Chrome.beta": .chromium, "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium, "org.chromium.Chromium": .chromium, "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium, "com.vivaldi.Vivaldi": .chromium, "company.thebrowser.Browser": .chromium,
        "com.operasoftware.Opera": .chromium
    ]
    private var scripts: [String: NSAppleScript] = [:]
    private var refused = Set<String>()
    private var asking = Set<String>()

    static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    /// The sanitized address, or nil for other apps, private windows, refusals and errors.
    func address(bundleID: String) -> String? {
        guard let family = Self.browsers[bundleID], !refused.contains(bundleID), !asking.contains(bundleID) else { return nil }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        if permission == OSStatus(errAEEventWouldRequireUserConsent) {
            asking.insert(bundleID)
            Task.detached(priority: .utility) { [weak self] in
                let answer = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
                await self?.answered(bundleID, allowed: answer == noErr)
            }
            return nil
        }
        guard permission == noErr else {
            if permission == OSStatus(errAEEventNotPermitted) { refused.insert(bundleID) }
            return nil
        }
        guard let script = scripts[bundleID] ?? compile(bundleID, family) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue, value != "private" else { return nil }
        return BrowserAddress.sanitized(value)
    }

    private func answered(_ bundleID: String, allowed: Bool) {
        asking.remove(bundleID)
        if !allowed { refused.insert(bundleID) }
    }

    private func compile(_ bundleID: String, _ family: Family) -> NSAppleScript? {
        // A one-second limit keeps a busy browser from holding up recording; incognito windows say so.
        let body = switch family {
        case .safari: "return URL of current tab of front window"
        case .chromium: "try\nif mode of front window is \"incognito\" then return \"private\"\nend try\nreturn URL of active tab of front window"
        }
        let source = """
            with timeout of 1 seconds
            tell application id "\(bundleID)"
            if (count of windows) is 0 then return ""
            \(body)
            end tell
            end timeout
            """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { return nil }
        scripts[bundleID] = script
        return script
    }
}
