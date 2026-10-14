import AppKit
import os
import SwiftUI
import RepriseCore
import UserNotifications

/// Waits for `operation` at most `seconds`. A capture stuck inside a system framework must not keep
/// Reprise from quitting or installing an update.
@MainActor func waitAtMost(_ seconds: Double, _ operation: @escaping @MainActor () async -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let done = OSAllocatedUnfairLock(initialState: false)
        let finish = { @Sendable in
            if done.withLock({ finished in defer { finished = true }; return !finished }) { continuation.resume() }
        }
        Task { @MainActor in await operation(); finish() }
        Task { try? await Task.sleep(for: .seconds(seconds)); finish() }
    }
}

@main
struct RepriseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.dropFirst() == ["--check-package"] { PackageCheck.run() }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-vault" { VaultCheck.run(path: CommandLine.arguments[2]) }
        let instance = Self.openLibrary()
        _model = StateObject(wrappedValue: instance); AppRuntime.model = instance
    }

    /// A missing key or a refused keychain read must not become a crash loop. When the keychain has
    /// no key for an encrypted library, a recovery key can put it back.
    private static func openLibrary() -> AppModel {
        var failure: Error
        do { return try AppModel() } catch { failure = error }
        while true {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Reprise could not open its library"
            alert.informativeText = failure.localizedDescription
            guard let keyFailure = failure as? VaultKeychain.Failure ?? (failure as? RecoveryKey.Failure).map({ _ in .missing }),
                  case .missing = keyFailure else {
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                exit(1)
            }
            alert.informativeText += "\n\nIf you saved this library's recovery key, paste it below to open the library on this Mac."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
            field.placeholderString = "R1-XXXXX-XXXXX-..."
            alert.accessoryView = field
            alert.addButton(withTitle: "Enter Recovery Key")
            alert.addButton(withTitle: "Quit")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
            do {
                try AppModel.restoreLibraryKey(field.stringValue)
                return try AppModel()
            } catch { failure = error }
        }
    }
    var body: some Scene {
        // Settings belongs to the memory panel's sheet, not a second launch scene.
        MenuBarExtra("Reprise", systemImage: "clock.arrow.circlepath", isInserted: Binding(get: { model.preferences.iconPlacement != .dock }, set: { _ in })) {
            MenuBarContent(model: model, capture: model.capture)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Images...") { Task { await model.importImages() } }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Memories...") { Task { await model.exportLibrary() } }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { delegate.explorer?.show(); model.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("Memory") {
                Button("Open Memory") { delegate.explorer?.show() }
                Button("Search Memory") { delegate.explorer?.showSearch() }.keyboardShortcut("f")
                Button("Back 30 Seconds") { model.skip(1) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Forward 30 Seconds") { model.skip(-1) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Frame") { model.step(1) }.keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Next Frame") { model.step(-1) }.keyboardShortcut(.rightArrow, modifiers: [.option])
                Button("Latest") { Task { model.dayFilter = nil; await model.reload() } }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var explorer: MemoryOverlayController?
    private var observer: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var restartObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private var powerOffObserver: NSObjectProtocol?
    private var poweringOff = false
    private var restartPending = false
    private var terminationTask: Task<Void, Never>?
    private var terminationReady = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        guard let model = AppRuntime.model else { return }
        model.updater.prepareForRelaunch = { [weak model] in
            guard let model else { return }
            UserDefaults.standard.set(model.capture.isRecording, forKey: "resumeCaptureAfterRestart")
            model.showSettings = false
            model.shutdown()
            await waitAtMost(5) { await model.capture.stop() }
            await model.meeting.stop()
            model.meeting.cancelTranscription()
        }
        model.applyPreferences()
        explorer = MemoryOverlayController(model: model)
        observer = NotificationCenter.default.addObserver(forName: .repriseOpenMemory, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.explorer?.show() }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: .repriseCloseMemory, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.explorer?.hide() }
        }
        restartObserver = NotificationCenter.default.addObserver(forName: .repriseRestart, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
        updateObserver = NotificationCenter.default.addObserver(forName: .repriseQuitForUpdate, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.closeSheetsAndQuit(resumeCapture: true) }
        }
        // Restart, shut down and log out quit apps too; recording that was on continues afterwards.
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }
        if model.showOnboarding || model.preferences.showOnLaunch { explorer?.show() }
        Task { await model.start() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A meeting summary notification opens that recording.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["momentID"] as? String
        Task { @MainActor in
            if let id { await AppRuntime.model?.openMemory(id: id) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { explorer?.show(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        if terminationTask != nil { return .terminateCancel }
        guard let model = AppRuntime.model else { return .terminateNow }
        model.endCaptureSession(poweringOff: poweringOff)
        model.shutdown(); model.meeting.cancelTranscription()
        if !model.capture.isRecording && !model.meeting.isRecording && !model.meeting.isBusy { return .terminateNow }
        // Return to the main queue before awaiting MainActor capture/audio cleanup.
        // terminateLater can enter a nested AppKit loop inside this dispatch block.
        terminationTask = Task {
            await waitAtMost(5) { await model.capture.stop() }
            await model.meeting.stop()
            terminationReady = true
            terminationTask = nil
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    private func restart() {
        guard !restartPending, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for normal shutdown to finish saving audio before relaunching the same bundle.
        helper.arguments = ["-c", "for n in $(/usr/bin/seq 1 300); do if ! kill -0 \"$1\" 2>/dev/null; then exec /usr/bin/open \"$2\"; fi; /bin/sleep 0.2; done", "reprise-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            restartPending = true
            closeSheetsAndQuit(resumeCapture: true)
        } catch { AppRuntime.model?.error = "Could not restart Reprise: \(error.localizedDescription)" }
    }

    private func closeSheetsAndQuit(resumeCapture: Bool) {
        UserDefaults.standard.set(resumeCapture && AppRuntime.model?.capture.isRecording == true, forKey: "resumeCaptureAfterRestart")
        AppRuntime.model?.showSettings = false
        AppRuntime.model?.showOnboarding = false
        // Let SwiftUI dismiss its sheet before AppKit handles application termination.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }
}

@MainActor private enum AppRuntime { static var model: AppModel? }
extension Notification.Name {
    static let repriseOpenMemory = Notification.Name("RepriseOpenMemory")
    static let repriseCloseMemory = Notification.Name("RepriseCloseMemory")
    static let repriseRestart = Notification.Name("RepriseRestart")
    static let repriseCapturePaused = Notification.Name("RepriseCapturePaused")
    static let repriseOverlayShown = Notification.Name("RepriseOverlayShown")
    static let repriseOverlayHidden = Notification.Name("RepriseOverlayHidden")
    static let repriseQuitForUpdate = Notification.Name("RepriseQuitForUpdate")
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureEngine
    var body: some View {
        Button("Open Memory") { NotificationCenter.default.post(name: .repriseOpenMemory, object: nil) }
        Divider()
        Text(capture.status)
        Button(capture.isRecording ? "Pause Recording" : "Start Recording") { Task { await model.toggleRecording() } }
        Button("Record Meeting") { NotificationCenter.default.post(name: .repriseOpenMemory, object: nil); Task { await model.toggleMeeting() } }
        Button("Settings...") { NotificationCenter.default.post(name: .repriseOpenMemory, object: nil); model.showSettings = true }
        Button("Check for Updates...") { model.updater.check() }.disabled(!model.updater.canCheck)
        Divider()
        Button("Quit Reprise") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
