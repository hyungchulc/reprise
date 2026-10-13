import AppKit
import Combine
import SwiftUI

@MainActor
final class PauseReminderController {
    private let model: AppModel
    private var panel: NSPanel?
    private var reminder: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var systemDialog = false

    init(model: AppModel) {
        self.model = model
        NotificationCenter.default.publisher(for: .repriseCapturePaused).sink { [weak self] _ in
            self?.schedule(after: 0.3)
        }.store(in: &subscriptions)
        model.capture.$isRecording.filter { $0 }.sink { [weak self] _ in
            self?.reminder?.cancel(); self?.panel?.orderOut(nil)
        }.store(in: &subscriptions)
        model.$preferences.sink { [weak self] preferences in
            if preferences.pauseReminders == false { self?.reminder?.cancel(); self?.panel?.orderOut(nil) }
        }.store(in: &subscriptions)
        model.$showSettings.combineLatest(model.$showOnboarding).sink { [weak self] settings, onboarding in
            if settings || onboarding { self?.panel?.orderOut(nil) }
        }.store(in: &subscriptions)
        if UserDefaults.standard.bool(forKey: "recordingManuallyPaused") { schedule(after: 15) }
    }

    deinit { reminder?.cancel() }

    func suspendForSystemDialog() { systemDialog = true; panel?.orderOut(nil) }
    func systemDialogFinished() { systemDialog = false }

    private func schedule(after seconds: Double) {
        reminder?.cancel()
        reminder = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.show()
        }
    }

    private func show() {
        guard !model.capture.isRecording, model.preferences.pauseReminders != false,
              UserDefaults.standard.bool(forKey: "recordingManuallyPaused") else { return }
        guard !systemDialog, !model.showSettings, !model.showOnboarding else { schedule(after: 30); return }
        if panel == nil {
            let notice = TransparentPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            notice.title = "Reprise is paused"
            notice.level = .normal
            notice.isOpaque = false
            notice.backgroundColor = .clear
            notice.hasShadow = true
            notice.isMovableByWindowBackground = true
            notice.isReleasedWhenClosed = false
            notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            notice.contentView = TransparentHostingView(rootView: PauseReminderView(model: model, resume: { [weak self] in
                self?.panel?.orderOut(nil)
                Task {
                    await self?.model.toggleRecording()
                    if self?.model.capture.isRecording == false {
                        NotificationCenter.default.post(name: .repriseOpenMemory, object: nil)
                    }
                }
            }, later: { [weak self] delay in
                self?.panel?.orderOut(nil); self?.schedule(after: delay)
            }))
            panel = notice
        }
        let frame = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel?.setFrame(NSRect(x: frame.maxX - 356, y: frame.maxY - 268, width: 332, height: 244), display: true)
        panel?.orderFrontRegardless()
    }
}

private struct PauseReminderView: View {
    @ObservedObject var model: AppModel
    let resume: () -> Void
    let later: (Double) -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text("Reprise is paused").repriseFont(.title)
            Button(action: resume) { Label("Resume Capturing", systemImage: "record.circle").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Menu {
                Button("In 15 minutes") { later(15 * 60) }
                Button("In 1 hour") { later(60 * 60) }
                Button("Tomorrow") { later(24 * 60 * 60) }
            } label: { Label("Remind Me Later", systemImage: "clock").frame(maxWidth: .infinity) }
                .menuStyle(.borderlessButton).controlSize(.large)
        }.padding(24).frame(width: 332, height: 244).modifier(GlassSurface())
            .repriseAppearance(model.preferences)
    }
}
