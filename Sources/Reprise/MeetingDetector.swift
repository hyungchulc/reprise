import AppKit
import Combine
import CoreGraphics

struct DetectedMeeting: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let appName: String
}

struct MeetingWindowMetadata: Sendable {
    let id: String
    let title: String
    let appName: String
    let bundleID: String
    var url: URL? = nil
    var isActive = false
}

/// Conservative hints from exposed metadata, not proof that a call is in progress.
enum MeetingWindowRules {
    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.canary", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera"
    ]
    private static let idleTitles: Set<String> = [
        "", "home", "zoom", "zoom workplace", "microsoft teams",
        "teams", "webex", "cisco webex meetings", "google meet", "meet", "calendar",
        "chat", "meetings", "sign in", "settings"
    ]
    private static let inactive = try! NSRegularExpression(
        pattern: #"\b(lobby|idle|waiting room|waiting for (the )?(host|organizer)|pre[- ]?join|ready to join|join (a |the )?meeting|not in (a )?(meeting|call)|meeting (has )?ended|call ended|sign in|sign out|schedule (a )?meeting)\b"#)
    private static let nativeMeeting = try! NSRegularExpression(
        pattern: #"^(?:(?:microsoft teams|cisco webex|webex)\s+)?(?:meeting|webinar)(?:$|\s*[:|-]|\s+with\b)|\b(?:in[- ]call|call with)\b|[-|]\s*(?:meeting|webinar)$"#)
    private static let meetTitle = try! NSRegularExpression(
        pattern: #"^(meet\s*[-:|]\s*[a-z]{3}-[a-z]{4}-[a-z]{3}\b|.+\s*[-|]\s*google meet$)"#)
    private static let urlInTitle = try! NSRegularExpression(
        pattern: #"https?://[^\s<>]+"#, options: [.caseInsensitive])

    static func classify(_ window: MeetingWindowMetadata) -> DetectedMeeting? {
        let title = String(window.title.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = title.lowercased()
        guard !idleTitles.contains(normalized), !matches(inactive, normalized),
              !normalized.hasPrefix("home |"), !normalized.hasPrefix("home -"),
              !normalized.hasSuffix("| home"), !normalized.hasSuffix("- home"),
              !normalized.hasPrefix("zoom workplace - home") else { return nil }

        let isMeeting: Bool
        if browsers.contains(window.bundleID) {
            isMeeting = matches(meetTitle, normalized)
                || window.url.map(isMeetingURL) == true
                || exposedURLs(in: title).contains(where: isMeetingURL)
        } else {
            switch window.bundleID {
            case "us.zoom.xos":
                isMeeting = normalized == "zoom meeting" || normalized == "zoom webinar"
                    || normalized.hasPrefix("zoom meeting -") || normalized.hasSuffix("- zoom meeting")
                    || normalized.hasPrefix("zoom webinar -") || normalized.hasSuffix("- zoom webinar")
            case "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.cisco.webexteams":
                isMeeting = matches(nativeMeeting, normalized)
            default:
                isMeeting = false
            }
        }
        guard isMeeting else { return nil }
        return DetectedMeeting(id: window.id, title: title, appName: window.appName)
    }

    static func isMeetingURL(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "meet.google.com" {
            return path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$"#, options: .regularExpression) != nil
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.range(of: #"^/(j/\d{9,11}|wc/\d{9,11}/join)/?$"#, options: .regularExpression) != nil
        }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) {
            return path.hasPrefix("/l/meetup-join/") && path.count > "/l/meetup-join/".count
        }
        if host.hasSuffix(".webex.com") {
            return path.hasPrefix("/meet/") && path.count > "/meet/".count
                || path.hasPrefix("/join/") && path.count > "/join/".count
        }
        return false
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func exposedURLs(in title: String) -> [URL] {
        urlInTitle.matches(in: title, range: NSRange(title.startIndex..., in: title)).prefix(4).compactMap {
            guard let range = Range($0.range, in: title) else { return nil }
            return URL(string: String(title[range]))
        }
    }
}

@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var candidate: DetectedMeeting?
    @Published var enabled = false {
        didSet { if enabled != oldValue { configurePolling() } }
    }

    private let pollInterval: TimeInterval
    private let snapshot: @MainActor () -> [MeetingWindowMetadata]
    private var pollingTask: Task<Void, Never>?
    private var dismissedIDs = Set<String>()

    init(pollInterval: TimeInterval = 8, snapshot: (@MainActor () -> [MeetingWindowMetadata])? = nil) {
        self.pollInterval = pollInterval.isFinite ? min(60, max(2, pollInterval)) : 8
        self.snapshot = snapshot ?? { Self.visibleWindows() }
    }

    deinit { pollingTask?.cancel() }

    func start() { enabled = true }
    func stop() { enabled = false }

    func dismiss() {
        if let candidate { dismissedIDs.insert(candidate.id) }
        candidate = nil
    }

    private func configurePolling() {
        pollingTask?.cancel()
        pollingTask = nil
        candidate = nil
        guard enabled else { dismissedIDs.removeAll(); return }
        poll()
        let interval = pollInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.poll()
                if self == nil { return }
            }
        }
    }

    private func poll() {
        guard enabled else { return }
        let windows = Array(snapshot().prefix(128))
        let meetings = windows.compactMap(MeetingWindowRules.classify)
        dismissedIDs.formIntersection(Set(windows.map(\.id)))
        let available = meetings.filter { !dismissedIDs.contains($0.id) }
        let activeIDs = Set(windows.filter(\.isActive).map(\.id))
        let next = available.first { activeIDs.contains($0.id) }
            ?? available.first { $0.id == candidate?.id }
            ?? available.first
        if next != candidate { candidate = next }
    }

    private static func visibleWindows() -> [MeetingWindowMetadata] {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { return [] }
        // Metadata only. No AX, Apple Events, screen pixels, or permission requests.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var apps: [pid_t: NSRunningApplication] = [:]
        return windows.prefix(128).compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowIsOnscreen as String] as? Bool == true,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let number = window[kCGWindowNumber as String] as? UInt32,
                  let title = window[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid)
            if let app { apps[pid] = app }
            guard let bundleID = app?.bundleIdentifier else { return nil }
            return MeetingWindowMetadata(id: "\(pid):\(number)", title: title,
                appName: app?.localizedName ?? window[kCGWindowOwnerName as String] as? String ?? "Application",
                bundleID: bundleID, isActive: pid == activePID)
        }
    }
}
