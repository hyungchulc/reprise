import AppKit
import SwiftUI
import RepriseCore

@main
struct RepriseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.dropFirst() == ["--check-package"] { PackageCheck.run() }
        do { let instance = try AppModel(); _model = StateObject(wrappedValue: instance); AppRuntime.model = instance }
        catch { fatalError("Unable to open Reprise library: \(error.localizedDescription)") }
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    var explorer: MemoryOverlayController?
    private var observer: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var restartObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private var restartPending = false
    private var terminationTask: Task<Void, Never>?
    private var terminationReady = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = AppRuntime.model else { return }
        model.updater.prepareForRelaunch = { [weak model] in
            guard let model else { return }
            UserDefaults.standard.set(model.capture.isRecording, forKey: "resumeCaptureAfterRestart")
            model.showSettings = false
            model.shutdown()
            await model.capture.stop()
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
        if model.showOnboarding || model.preferences.showOnLaunch { explorer?.show() }
        Task { await model.start() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { explorer?.show(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        if terminationTask != nil { return .terminateCancel }
        guard let model = AppRuntime.model else { return .terminateNow }
        model.shutdown(); model.meeting.cancelTranscription()
        if !model.capture.isRecording && !model.meeting.isRecording && !model.meeting.isBusy { return .terminateNow }
        // Return to the main queue before awaiting MainActor capture/audio cleanup.
        // terminateLater can enter a nested AppKit loop inside this dispatch block.
        terminationTask = Task {
            await model.capture.stop()
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
