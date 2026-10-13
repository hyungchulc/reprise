import AppKit
import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var shortcut: GlobalShortcut
    var body: some View {
        LabeledContent("Search Memory") {
            HStack {
                ShortcutRecorder(shortcut: shortcut).frame(width: 246, height: 28)
                Button { shortcut.restoreDefault() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Restore default shortcut")
            }
        }.onDisappear { if shortcut.isRecording { shortcut.cancelRecording() } }
        if let error = shortcut.error { Text(error).foregroundStyle(.red).repriseFont(.caption) }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var shortcut: GlobalShortcut
    @Environment(\.repriseTextSize) private var textSize

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.shortcut = shortcut
        button.target = button
        button.action = #selector(ShortcutRecorderButton.toggleRecording)
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("Search Memory shortcut")
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.title = shortcut.isRecording ? "Press shortcut..." : shortcut.configuration.title
        button.font = .systemFont(ofSize: textSize)
        button.setAccessibilityValue(shortcut.isRecording ? "Recording shortcut" : shortcut.configuration.title)
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
