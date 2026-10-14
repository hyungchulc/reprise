import AppKit
import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var shortcut: GlobalShortcut
    var title = "Search Memory"
    var body: some View {
        LabeledContent(title) {
            HStack {
                ShortcutRecorder(shortcut: shortcut, title: title).frame(width: 246, height: 28)
                if shortcut.hasDefault {
                    Button { shortcut.restoreDefault() } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Restore default shortcut")
                } else {
                    Button { shortcut.restoreDefault() } label: { Image(systemName: "xmark.circle") }
                        .help("Remove shortcut").disabled(shortcut.configuration == nil)
                }
            }
        }.onDisappear { if shortcut.isRecording { shortcut.cancelRecording() } }
        if let error = shortcut.error { Text(error).foregroundStyle(.red).repriseFont(.caption) }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var shortcut: GlobalShortcut
    let title: String
    @Environment(\.repriseTextSize) private var textSize

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.shortcut = shortcut
        button.target = button
        button.action = #selector(ShortcutRecorderButton.toggleRecording)
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("\(title) shortcut")
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        let current = shortcut.configuration?.title ?? "Record Shortcut"
        button.title = shortcut.isRecording ? "Press shortcut..." : current
        button.font = .systemFont(ofSize: textSize)
        button.setAccessibilityValue(shortcut.isRecording ? "Recording shortcut" : shortcut.configuration?.title ?? "None")
    }
}

private final class ShortcutRecorderButton: NSButton {
    weak var shortcut: GlobalShortcut?
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    @objc func toggleRecording() {
        guard let shortcut else { return }
        if shortcut.isRecording { shortcut.cancelRecording() }
        else {
            window?.makeKey()
            window?.makeFirstResponder(self)
            shortcut.beginRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        if shortcut?.isRecording == true { shortcut?.receive(event) }
        else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if shortcut?.isRecording == true { shortcut?.receive(event); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if shortcut?.isRecording == true { shortcut?.cancelRecording() }
        return super.resignFirstResponder()
    }
}
