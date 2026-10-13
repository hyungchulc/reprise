import AppKit
import SwiftUI

// Own Return handling so a borderless panel cannot turn submit into select-all.
struct MemorySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var fontSize: CGFloat
    var placeholder = "Search your memory"
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search your memory"
        field.setAccessibilityLabel("Search your memory")
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        field.setFocusRequested(isFocused)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MemorySearchField
        init(_ parent: MemorySearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { if !parent.isFocused { parent.isFocused = true } }
        func controlTextDidEndEditing(_ notification: Notification) { if parent.isFocused { parent.isFocused = false } }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(),
                  let field = control as? NSTextField else { return false }
            parent.text = field.stringValue
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            parent.isFocused = false
            field.window?.makeFirstResponder(nil)
            parent.onSubmit()
            return true
        }
    }
}

final class SearchTextField: NSTextField {
    private var wantsFocus = false
    private var pendingFocus = false
    private var keyObserver: NSObjectProtocol?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setFocusRequested(_ requested: Bool) {
        if requested != wantsFocus { pendingFocus = requested; wantsFocus = requested }
        if !requested, currentEditor() != nil { window?.makeFirstResponder(nil) }
        applyPendingFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let window {
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.applyPendingFocus()
            }
        }
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard pendingFocus, let window, window.isKeyWindow else { return }
        pendingFocus = false
        guard currentEditor() == nil else { return }
        if window.makeFirstResponder(self), let editor = currentEditor() {
            editor.selectedRange = NSRange(location: stringValue.utf16.count, length: 0)
        }
    }

    deinit { if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) } }
}
