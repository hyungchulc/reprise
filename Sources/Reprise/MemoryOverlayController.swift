import AppKit
import SwiftUI
import RepriseCore
import Combine

@MainActor
final class MemoryOverlayController {
    private let model: AppModel
    private let panel: MemoryPanel
    private var events: Any?
    private var previousApplication: NSRunningApplication?
    private var meetingPanel: NSPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var restoreAfterSystemDialog = false
    private var dialogWindows: [NSWindow] = []
    private var systemDialogPresented = false
    private var pauseReminder: PauseReminderController?
    private var previousPresentation: NSApplication.PresentationOptions?
    private var configuredScreenFrame: NSRect?
    private var captionWindow: CaptionWindowController?
    private var assistantPanel: AssistantPanelController?
    /// When each on-and-off shortcut last acted; one press can arrive as a hotkey and as a key event.
    private var lastToggle: [UInt32: Date] = [:]

    init(model: AppModel) {
        self.model = model
        panel = MemoryPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Reprise Memory"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = TransparentHostingView(rootView: MemoryExplorerView(model: model, topInset: 40, cornerRadius: 0))
        panel.initialFirstResponder = panel.contentView
        panel.onEscape = { [weak self] in self?.handleEscape() }
        pauseReminder = PauseReminderController(model: model)
        model.permissions.willPresentSystemDialog = { [weak self] in
            guard let self, !self.systemDialogPresented else { return }
            self.systemDialogPresented = true
            self.restorePresentation()
            self.restoreAfterSystemDialog = self.panel.isVisible
            self.dialogWindows = NSApp.windows.filter { $0 !== self.panel && $0.isVisible && $0.canBecomeKey && $0.level >= .floating }
            self.dialogWindows.forEach { $0.orderOut(nil) }
            self.panel.orderOut(nil)
            self.meetingPanel?.orderOut(nil)
            self.pauseReminder?.suspendForSystemDialog()
        }
        model.permissions.didFinishSystemDialog = { [weak self] in self?.restoreAfterPermission() }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.restoreAfterPermission(); self?.updatePresentation() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.restorePresentation() }
            .store(in: &subscriptions)
        model.$showSettings.combineLatest(model.$showOnboarding, model.$searchOnly).receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updatePresentation() }
            .store(in: &subscriptions)
        model.shortcut.onTrigger = { [weak self] in self?.showSearch() }
        model.shortcut.activate()
        model.searchOnlyShortcut.onTrigger = { [weak self] in self?.showSearch(only: true) }
        model.searchOnlyShortcut.activate()
        captionWindow = CaptionWindowController(captions: model.captions) { [weak model] center in
            model?.preferences.captions.center = center
            model?.preferences.captions.position = .custom
        }
        model.captionsShortcut.onTrigger = { [weak self] in self?.toggleOnce(3) { await $0.toggleCaptions() } }
        model.captionsShortcut.activate()
        model.meetingShortcut.onTrigger = { [weak self] in self?.toggleOnce(4) { await $0.toggleMeeting(announce: true) } }
        model.meetingShortcut.activate()
        assistantPanel = AssistantPanelController(model: model)
        model.assistantShortcut.onTrigger = { [weak self] in self?.toggleOnce(5) { await $0.toggleAssistant() } }
        model.assistantShortcut.activate()
        model.answerShortcut.onTrigger = { [weak self] in self?.toggleOnce(6) { await $0.answerLastQuestion() } }
        model.answerShortcut.activate()
        events = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Local key equivalents can arrive without Carbon's global hotkey event.
            if event.type == .keyDown, self.model.shortcut.matches(event) {
                self.showSearch(); return nil
            }
            if event.type == .keyDown, self.model.searchOnlyShortcut.matches(event) {
                self.showSearch(only: true); return nil
            }
            if event.type == .keyDown, self.model.captionsShortcut.matches(event) {
                self.toggleOnce(3) { await $0.toggleCaptions() }; return nil
            }
            if event.type == .keyDown, self.model.meetingShortcut.matches(event) {
                self.toggleOnce(4) { await $0.toggleMeeting(announce: true) }; return nil
            }
            if event.type == .keyDown, self.model.assistantShortcut.matches(event) {
                self.toggleOnce(5) { await $0.toggleAssistant() }; return nil
            }
            if event.type == .keyDown, self.model.answerShortcut.matches(event) {
                self.toggleOnce(6) { await $0.answerLastQuestion() }; return nil
            }
            guard event.window === self.panel else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.panel.attachedSheet == nil {
                if (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
                if !event.isARepeat { self.handleEscape() }
                return nil
            }
            return event
        }
        model.meetingDetector.$candidate.sink { [weak self] candidate in
            Task { @MainActor in self?.showMeetingNotice(candidate) }
        }.store(in: &subscriptions)
        model.meeting.$isRecording.sink { [weak self] recording in
            if recording { self?.meetingPanel?.orderOut(nil) }
        }.store(in: &subscriptions)
    }

    func show() {
        let wasVisible = panel.isVisible
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let topInset = (screen?.safeAreaInsets.top ?? 0) + 12
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1300, height: 850)
        if configuredScreenFrame != frame, let hosting = panel.contentView as? TransparentHostingView<MemoryExplorerView> {
            hosting.rootView = MemoryExplorerView(model: model, topInset: topInset, cornerRadius: (screen?.safeAreaInsets.top ?? 0) > 0 ? 18 : 0)
            configuredScreenFrame = frame
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.contentView?.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible { panel.makeFirstResponder(panel.contentView) }
        meetingPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        updatePresentation()
        model.permissions.refresh()
        if !wasVisible {
            model.dayFilter = nil
            Task { await model.reload(preserve: true) }
            NotificationCenter.default.post(name: .repriseOverlayShown, object: nil)
        }
    }

    func hide() {
        model.searchOnly = false
        restoreAfterSystemDialog = false
        restorePresentation()
        panel.orderOut(nil)
        model.endTimelineInteraction()
        NotificationCenter.default.post(name: .repriseOverlayHidden, object: nil)
        model.endSearchSession()
        if previousApplication?.activate(options: []) != true {
            NSApp.hide(nil)
        }
    }

    private func toggleOnce(_ shortcut: UInt32, _ action: @escaping (AppModel) async -> Void) {
        if let last = lastToggle[shortcut], Date().timeIntervalSince(last) < 0.4 { return }
        lastToggle[shortcut] = Date()
        let model = model
        Task { await action(model) }
    }

    private func handleEscape() {
        if !model.dismissSearch() { hide() }
    }

    /// `only` shows just the search box. It leaves an open full view as it is; the plain shortcut
    /// always shows the full view.
    func showSearch(only: Bool = false) {
        guard !systemDialogPresented, panel.attachedSheet == nil, !model.showSettings, !model.showOnboarding else { return }
        if !only || !panel.isVisible { model.searchOnly = only }
        show()
        NotificationCenter.default.post(name: .repriseFocusSearch, object: nil)
    }

    private func updatePresentation() {
        // The search box alone leaves the menu bar and Dock in place, as a small panel would.
        guard panel.isVisible, NSApp.isActive, !systemDialogPresented,
              !model.showSettings, !model.showOnboarding, !model.searchOnly else { restorePresentation(); return }
        if previousPresentation == nil { previousPresentation = NSApp.presentationOptions }
        // AppKit requires hideDock with hideMenuBar. Neither is a global preference.
        var options = NSApp.presentationOptions
        options.subtract([.autoHideMenuBar, .autoHideDock, .autoHideToolbar])
        options.formUnion([.hideMenuBar, .hideDock])
        NSApp.presentationOptions = options
    }

    private func restorePresentation() {
        guard let previousPresentation else { return }
        NSApp.presentationOptions = previousPresentation
        self.previousPresentation = nil
    }

    private func restoreAfterPermission() {
        guard NSApp.isActive, model.permissions.requesting == nil else { return }
        systemDialogPresented = false
        pauseReminder?.systemDialogFinished()
        if restoreAfterSystemDialog {
            restoreAfterSystemDialog = false
            panel.makeKeyAndOrderFront(nil)
        }
        dialogWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        dialogWindows.removeAll()
        model.permissions.refresh()
        updatePresentation()
    }

    private func showMeetingNotice(_ candidate: DetectedMeeting?) {
        guard candidate != nil, !model.meeting.isRecording, !panel.isVisible else { meetingPanel?.orderOut(nil); return }
        if meetingPanel == nil {
            let notice = TransparentPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            notice.level = .floating; notice.isOpaque = false; notice.backgroundColor = .clear
            notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            notice.contentView = TransparentHostingView(rootView: MeetingPrompt(model: model, detector: model.meetingDetector, recorder: model.meeting))
            meetingPanel = notice
        }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        meetingPanel?.setFrame(NSRect(x: screen.maxX - 596, y: screen.maxY - 98, width: 580, height: 82), display: true)
        meetingPanel?.orderFrontRegardless()
    }
}

private final class MemoryPanel: TransparentPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var overlayBackgroundColor: NSColor { .black.withAlphaComponent(0.02) }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { makeKey() }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
