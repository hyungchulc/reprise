import AppKit
import Carbon
import Combine

struct ShortcutConfiguration: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    static let standard = ShortcutConfiguration(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "Space")
    var title: String {
        [(UInt32(controlKey), "Control"), (UInt32(optionKey), "Option"), (UInt32(shiftKey), "Shift"), (UInt32(cmdKey), "Command")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined(separator: " + ") + " + " + keyLabel
    }
}

@MainActor
final class GlobalShortcut: ObservableObject {
    @Published private(set) var configuration: ShortcutConfiguration
    @Published private(set) var isRecording = false
    @Published private(set) var error: String?
    var onTrigger: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        configuration = UserDefaults.standard.data(forKey: "memoryShortcut")
            .flatMap { try? JSONDecoder().decode(ShortcutConfiguration.self, from: $0) } ?? .standard
    }

    func activate() {
        guard handler == nil else { return }
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.onTrigger?() }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        register(configuration)
    }

    func beginRecording() {
        guard !isRecording else { return }
        unregister(); error = nil; isRecording = true
    }

    func receive(_ event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == kVK_Escape { cancelRecording(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else {
            error = "Include Command, Option, or Control."; return
        }
        let labels: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "Left", 124: "Right", 125: "Down", 126: "Up"]
        let label = labels[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "Key \(event.keyCode)"
        save(ShortcutConfiguration(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(event), keyLabel: label))
    }

    func matches(_ event: NSEvent) -> Bool {
        !isRecording && !event.isARepeat && UInt32(event.keyCode) == configuration.keyCode
            && carbonModifiers(event) == configuration.modifiers
    }

    private func carbonModifiers(_ event: NSEvent) -> UInt32 {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    func cancelRecording() {
        endRecording()
        register(configuration)
    }

    func restoreDefault() { save(.standard) }

    private func save(_ candidate: ShortcutConfiguration) {
        unregister()
        guard register(candidate) else {
            if !isRecording { _ = register(configuration, preserveError: true) }
            return
        }
        configuration = candidate
        UserDefaults.standard.set(try? JSONEncoder().encode(candidate), forKey: "memoryShortcut")
        endRecording()
    }

    @discardableResult private func register(_ value: ShortcutConfiguration, preserveError: Bool = false) -> Bool {
        guard hotKey == nil else { return true }
        let result = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x52505253, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { error = "That shortcut is unavailable or used by another app."; return false }
        if !preserveError { error = nil }
        return true
    }

    private func unregister() { if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil }
    private func endRecording() {
        isRecording = false
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
