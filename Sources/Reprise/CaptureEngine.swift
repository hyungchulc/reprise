import AppKit
import Combine
import ScreenCaptureKit
import RepriseCore
import IOKit.ps

@MainActor
final class CaptureEngine: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Paused"
    @Published private(set) var lastError: String?
    @Published private(set) var capturedCount = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var lastCapture: Date?

    private let store: MomentStore
    private let root: URL
    private let processor = CaptureImageProcessor()
    private var loop: Task<Void, Never>?
    private var busy = false
    private var generation = UUID()
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    private var lastFingerprint: String?
    private var lastContext: String?

    init(store: MomentStore, root: URL) {
        self.store = store
        self.root = root
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sleeping = true; self?.generation = UUID() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sleeping = false }
            })
        }
    }

    deinit {
        loop?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func start(settings: CaptureSettings) async {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            lastError = "Allow Screen Recording in System Settings before starting."
            status = "Screen Recording permission required"
            return
        }
        isRecording = true
        lastError = nil
        generation = UUID()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { break }
                await self.captureOnce(settings: settings)
                let interval = settings.interval.isFinite ? max(1, min(settings.interval, 300)) : 3
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            }
        }
    }

    func stop() async {
        isRecording = false
        generation = UUID()
        let oldLoop = loop
        loop = nil
        oldLoop?.cancel()
        await oldLoop?.value
        if !isRecording { status = "Paused" }
    }

    func captureOnce(settings: CaptureSettings) async {
        guard !busy else { skippedCount += 1; return }
        busy = true
        defer { busy = false }
        let token = generation
        var prepared: PreparedCapture?
        do {
            if let reason = pauseReason(settings: settings) { skip(reason); return }
            guard CGPreflightScreenCaptureAccess() else {
                status = "Screen Recording permission required"
                return
            }
            let before = foregroundContext()
            if let reason = privacyReason(before, settings: settings) { skip(reason); return }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard token == generation, pauseReason(settings: settings) == nil else { return }
            let window = content.windows.first { $0.owningApplication?.processID == before.pid && $0.windowLayer == 0 }
            let display = content.displays.first { display in
                guard let window else { return display.displayID == CGMainDisplayID() }
                return display.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
            } ?? content.displays.first
            guard let display else { throw CaptureFailure("No display available.") }
            // Pause for private titles anywhere on this display, including background windows.
            if content.windows.contains(where: { $0.frame.intersects(display.frame) && isPrivate($0.title ?? "", settings) }) {
                skip("Paused for a private window"); return
            }
            let excluded = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
                    || settings.excludedBundleIDs.contains($0.bundleIdentifier)
            }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let pixelScale = CGFloat(filter.pointPixelScale)
            let size = settings.pixelDimensions(width: Int((filter.contentRect.width * pixelScale).rounded()),
                                                height: Int((filter.contentRect.height * pixelScale).rounded()))
            configuration.width = size.width
            configuration.height = size.height
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.queueDepth = 3
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard token == generation, !Task.isCancelled, pauseReason(settings: settings) == nil,
                  foregroundContext() == before, privacyReason(before, settings: settings) == nil else { skip("Skipped changed context"); return }
            let contextKey = "\(display.displayID)|\(before.pid)|\(before.title)"
            prepared = try await processor.prepare(image: image, root: root, cipher: store.cipher, settings: settings,
                previousFingerprint: settings.deduplicate && contextKey == lastContext ? lastFingerprint : nil,
                ignoringTopRows: menuBarRows(display: display, window: window, image: image, pointHeight: filter.contentRect.height))
            guard let result = prepared else { skip("Recording, unchanged screen"); return }
            guard token == generation, !Task.isCancelled, pauseReason(settings: settings) == nil,
                  foregroundContext() == before, privacyReason(before, settings: settings) == nil else {
                await processor.remove(result, root: root); prepared = nil
                skip("Skipped changed context"); return
            }
            let moment = Moment(timestamp: result.timestamp, appName: before.name, bundleID: before.bundleID,
                                windowTitle: before.title, text: result.text, imagePath: result.imagePath,
                                thumbnailPath: result.thumbnailPath, byteCount: result.byteCount)
            try await store.insert(moment)
            prepared = nil
            lastFingerprint = result.fingerprint
            lastContext = contextKey
            capturedCount += 1
            lastCapture = result.timestamp
            lastError = result.ocrWarning
            status = isRecording ? "Recording" : "Captured"
            // Storage limits are enforced periodically without adding another background queue.
            if capturedCount == 1 || capturedCount % 20 == 0 {
                let gb = settings.storageLimitGB.isFinite ? max(0.1, min(settings.storageLimitGB, 10000)) : 10
                _ = try await store.prune(retentionDays: max(1, settings.retentionDays), maxBytes: Int64(gb * 1_000_000_000))
            }
        } catch is CancellationError {
            if let prepared { await processor.remove(prepared, root: root) }
        } catch {
            if let prepared { await processor.remove(prepared, root: root) }
            lastError = error.localizedDescription
            status = "Capture unavailable"
        }
    }

    private func skip(_ reason: String) { skippedCount += 1; status = reason }

    /// Image rows under the display's menu bar, or none when a full-screen window covers the top edge.
    private func menuBarRows(display: SCDisplay, window: SCWindow?, image: CGImage, pointHeight: CGFloat) -> Int {
        if let window, window.frame.minY <= display.frame.minY + 0.5 { return 0 }
        guard pointHeight > 0, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }) else { return 0 }
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        return Int((menuBar / pointHeight * CGFloat(image.height)).rounded(.up))
    }

    private func pauseReason(settings: CaptureSettings) -> String? {
        if sleeping { return "Paused while asleep or locked" }
        // A floating Reprise window may remain visible after another app activates.
        if NSApp.windows.contains(where: { $0.canBecomeKey && $0.isVisible && $0.isOnActiveSpace && $0.occlusionState.contains(.visible) }) {
            return "Paused while viewing Reprise"
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { return "Paused while locked" }
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) > 300 {
            return "Paused while idle"
        }
        if settings.pauseOnBattery, let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue(), source as String == kIOPSBatteryPowerValue {
            return "Paused on battery"
        }
        return nil
    }

    private func foregroundContext() -> CaptureContext {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let window = windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        return CaptureContext(pid: pid, name: app?.localizedName ?? "Unknown app", bundleID: app?.bundleIdentifier ?? "",
                              title: window?[kCGWindowName as String] as? String ?? "")
    }

    private func privacyReason(_ context: CaptureContext, settings: CaptureSettings) -> String? {
        if context.pid == 0 { return "Paused, no active app" }
        if context.pid == ProcessInfo.processInfo.processIdentifier { return "Paused in Reprise" }
        if settings.excludedBundleIDs.contains(context.bundleID) { return "Paused for an excluded app" }
        if isPrivate(context.title, settings) { return "Paused for a private window" }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if windows.contains(where: { isPrivate($0[kCGWindowName as String] as? String ?? "", settings) }) {
            return "Paused for a private window"
        }
        return nil
    }

    private func isPrivate(_ title: String, _ settings: CaptureSettings) -> Bool {
        settings.excludedTitleTerms.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.localizedCaseInsensitiveContains($0) }
    }
}

private struct CaptureContext: Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String
    let title: String
}
