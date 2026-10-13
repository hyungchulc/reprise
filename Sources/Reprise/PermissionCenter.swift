import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Speech

@MainActor
final class PermissionCenter: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case screenCapture, microphone, speech
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .screenCapture: return "Screen & System Audio"
            case .microphone: return "Microphone"
            case .speech: return "Speech Recognition"
            }
        }
        fileprivate var settingsPane: String {
            switch self {
            case .screenCapture: return "Privacy_ScreenCapture"
            case .microphone: return "Privacy_Microphone"
            case .speech: return "Privacy_SpeechRecognition"
            }
        }
    }

    enum Status: String, Sendable {
        case unknown, notDetermined, authorized, denied, restricted
        var displayName: String {
            switch self {
            case .unknown: return "Access not available to this app"
            case .notDetermined: return "Not requested"
            case .authorized: return "Allowed"
            case .denied: return "Not allowed"
            case .restricted: return "Restricted"
            }
        }
    }

    @Published private(set) var screenCapture: Status = .unknown
    @Published private(set) var microphone: Status = .unknown
    @Published private(set) var speech: Status = .unknown
    @Published private(set) var requesting: Kind?
    @Published private(set) var lastError: String?
    @Published private(set) var screenAccessNeedsRefresh = false
    var willPresentSystemDialog: (() -> Void)?
    var didFinishSystemDialog: (() -> Void)?
    private var activation: AnyCancellable?
    private var refreshTask: Task<Void, Never>?

    init() {
        refresh()
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    deinit { refreshTask?.cancel() }

    func status(for kind: Kind) -> Status {
        switch kind {
        case .screenCapture: return screenCapture
        case .microphone: return microphone
        case .speech: return speech
        }
    }

    /// Reads authorization without requesting it or starting any capture.
    func refresh() {
        // Public screen preflight cannot distinguish denial from a first request.
        screenCapture = CGPreflightScreenCaptureAccess() ? .authorized : .unknown
        if screenCapture == .authorized { screenAccessNeedsRefresh = false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: microphone = .notDetermined
        case .authorized: microphone = .authorized
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        @unknown default: microphone = .unknown
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: speech = .notDetermined
        case .authorized: speech = .authorized
        case .denied: speech = .denied
        case .restricted: speech = .restricted
        @unknown default: speech = .unknown
        }
    }

    /// Call only from an explicit permission button action, never from detection or startup.
    func request(_ kind: Kind) async {
        guard requesting == nil else { return }
        refresh()
        lastError = nil
        guard status(for: kind) != .authorized else { return }
        guard status(for: kind) != .restricted, status(for: kind) != .denied else { return }
        let usageKey: String?
        switch kind {
        case .screenCapture: usageKey = nil
        case .microphone: usageKey = "NSMicrophoneUsageDescription"
        case .speech: usageKey = "NSSpeechRecognitionUsageDescription"
        }
        if let usageKey, (Bundle.main.object(forInfoDictionaryKey: usageKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            lastError = "The app bundle is missing \(usageKey)."
            return
        }
        requesting = kind
        var waitingInSettings = false
        defer {
            requesting = nil
            refresh()
            watchForChanges()
            if !waitingInSettings { didFinishSystemDialog?() }
        }
        guard !Task.isCancelled else { return }
        willPresentSystemDialog?()
        switch kind {
        case .screenCapture:
            screenAccessNeedsRefresh = true
            if !CGRequestScreenCaptureAccess() {
                waitingInSettings = openSettings(.screenCapture)
            }
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
    }

    /// Open only from a user action. Carbon RegisterEventHotKey needs no AX permission.
    @discardableResult func openSettings(_ kind: Kind) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)") else { return false }
        if kind == .screenCapture { screenAccessNeedsRefresh = true }
        willPresentSystemDialog?()
        if !NSWorkspace.shared.open(url) {
            lastError = "Could not open Privacy & Security settings."
            didFinishSystemDialog?()
            return false
        }
        watchForChanges()
        return true
    }

    private func watchForChanges() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refresh()
            }
        }
    }
}
