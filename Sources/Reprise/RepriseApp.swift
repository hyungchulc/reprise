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
            CommandMenu("Audio") { AudioMenuItems(model: model, meeting: model.meeting, captions: model.captions, assistant: model.assistant) }
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
    private var captureWatch: Task<Void, Never>?
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
        // A restart Reprise makes on its own comes back in the background, without its window.
        if model.showOnboarding || (model.preferences.showOnLaunch && !UserDefaults.standard.bool(forKey: AppModel.quietLaunchKey)) { explorer?.show() }
        Task { await model.start() }
        watchCapture()
    }

    private static let stuckRestart = "stuckCaptureRestart"

    /// A system call that never returns, such as a Vision request after the macOS 27.2 update, holds
    /// text recognition, or capture itself, until the process ends. When text recognition has failed
    /// for ten minutes in a row or a capture has run for ten minutes, Reprise restarts itself, at most
    /// once an hour, once no window is open and nothing would be cut short. Screens saved without
    /// their text meanwhile are read after the restart.
    private func watchCapture() {
        captureWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let model = AppRuntime.model else { return }
                let trouble = TextReadingLane.shared.trouble
                let textStuck = trouble.map { $0.failures >= 5 && abs($0.since.timeIntervalSinceNow) >= 600 } ?? false
                let captureStuck = model.capture.busySince.map { abs($0.timeIntervalSinceNow) >= 600 } ?? false
                guard textStuck || captureStuck else { continue }
                let last = UserDefaults.standard.object(forKey: Self.stuckRestart) as? Date
                guard last.map({ abs($0.timeIntervalSinceNow) >= 3_600 }) ?? true, !model.hasWorkInProgress,
                      !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) else { continue }
                UserDefaults.standard.set(Date(), forKey: Self.stuckRestart)
                self.restart(quietly: true)
                return
            }
        }
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

    /// `quietly` opens Reprise again in the background, without its window, and ends a process that
    /// has not quit within 20 seconds: a Vision request that never returns may hold it.
    private func restart(quietly: Bool = false) {
        guard !restartPending, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for normal shutdown to finish saving audio before relaunching the same bundle.
        let script = quietly
            ? "wait_for() { for n in $(/usr/bin/seq 1 \"$1\"); do if ! kill -0 \"$2\" 2>/dev/null; then exec /usr/bin/open -g \"$3\" --args -\(AppModel.quietLaunchKey) YES; fi; /bin/sleep 0.2; done; }; wait_for 100 \"$1\" \"$2\"; kill -KILL \"$1\"; wait_for 50 \"$1\" \"$2\""
            : "for n in $(/usr/bin/seq 1 300); do if ! kill -0 \"$1\" 2>/dev/null; then exec /usr/bin/open \"$2\"; fi; /bin/sleep 0.2; done"
        helper.arguments = ["-c", script, "reprise-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
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
        AudioMenuItems(model: model, meeting: model.meeting, captions: model.captions, assistant: model.assistant)
        Divider()
        Button("Settings...") { NotificationCenter.default.post(name: .repriseOpenMemory, object: nil); model.showSettings = true }
        Button("Check for Updates...") { model.updater.check() }.disabled(!model.updater.canCheck)
        Divider()
        Button("Quit Reprise") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Meeting recording, the meeting assistant and live captions, in the menu bar menu and the app's Audio menu.
struct AudioMenuItems: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingRecorder
    @ObservedObject var captions: LiveCaptions
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        Button(meeting.isRecording ? "Stop Meeting Recording" : "Record Meeting") {
            NotificationCenter.default.post(name: .repriseOpenMemory, object: nil)
            Task { await model.toggleMeeting() }
        }.disabled(meeting.isBusy)
        Picker("Transcribe With", selection: $model.preferences.transcriptionEngine) {
            ForEach(TranscriptionEngine.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Toggle("Meeting Assistant", isOn: Binding(get: { assistant.isRunning }, set: { _ in Task { await model.toggleAssistant() } }))
        Button("Answer Last Question") { Task { await model.answerLastQuestion() } }.disabled(!assistant.isRunning)
        Toggle("Live Captions", isOn: Binding(get: { captions.isRunning }, set: { _ in Task { await model.toggleCaptions() } }))
        Button("Move Captions...") { model.moveCaptions() }
    }
}
