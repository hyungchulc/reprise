import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var message = "GitHub alpha releases. Downloads are verified with an Ed25519 signature."
    @Published var automaticChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    var prepareForRelaunch: (() async -> Void)?
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            message = "Updates are available in packaged releases."; return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            automaticChecks = controller.updater.automaticallyChecksForUpdates
            observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                Task { @MainActor in self?.canCheck = change.newValue ?? false }
            }
        } catch { message = "Updater could not start: \(error.localizedDescription)" }
    }

    func check() {
        guard canCheck else { return }
        NotificationCenter.default.post(name: .repriseCloseMemory, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.controller?.checkForUpdates(nil) }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { message = error.localizedDescription }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        message = "Version \(item.displayVersionString) is available."
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        Task { @MainActor in
            await prepareForRelaunch?()
            installHandler()
        }
        return true
    }
}

struct UpdateSettings: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Section("Updates") {
            LabeledContent("Channel", value: "GitHub Alpha")
            Toggle("Automatically check for updates", isOn: $updater.automaticChecks)
            Text(updater.message).foregroundStyle(.secondary).repriseFont(.caption)
            Button("Check for Updates", systemImage: "arrow.clockwise") { dismiss(); updater.check() }.disabled(!updater.canCheck)
            Link("Release Notes", destination: URL(string: "https://github.com/hyungchulc/reprise/releases")!)
        }
    }
}
