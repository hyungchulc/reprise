import AppKit
@preconcurrency import AVFoundation
import RepriseCore
import SwiftUI

/// Who makes live captions.
enum CaptionEngine: String, Codable, CaseIterable, Identifiable {
    /// OpenAI when an account works, otherwise this Mac.
    case automatic
    case openAI
    case onDevice
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .openAI: "OpenAI, online"
        case .onDevice: "On this Mac"
        }
    }
}

enum CaptionPosition: String, Codable, CaseIterable, Identifiable {
    case bottom, top, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .bottom: "Bottom"; case .top: "Top"; case .custom: "Where I moved it" }
    }
}

struct CaptionPreferences: Codable, Equatable {
    var engine = CaptionEngine.automatic
    var input = LiveAudioInput.system
    /// The language captions are written in; empty shows the spoken language as it is.
    var target = CaptionPreferences.systemLanguage
    /// The spoken language, as a BCP 47 identifier. Captions on this Mac need it; empty lets OpenAI recognize it.
    var spoken = ""
    var showOriginal = false
    var textSize = 30.0
    var textColor = "#FFFFFF"
    var backgroundOpacity = 0.55
    var lines = 2
    var position = CaptionPosition.bottom
    /// The middle of the captions after they were moved, in screen coordinates.
    var center: [Double]?

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptionPreferences()
        engine = values.value(.engine, default: defaults.engine)
        input = values.value(.input, default: defaults.input)
        target = values.value(.target, default: defaults.target)
        spoken = values.value(.spoken, default: defaults.spoken)
        showOriginal = values.value(.showOriginal, default: defaults.showOriginal)
        textSize = values.value(.textSize, default: defaults.textSize)
        textColor = values.value(.textColor, default: defaults.textColor)
        backgroundOpacity = values.value(.backgroundOpacity, default: defaults.backgroundOpacity)
        lines = values.value(.lines, default: defaults.lines)
        position = values.value(.position, default: defaults.position)
        center = values.value(.center, default: defaults.center)
    }

    var color: Color { Color(hex: textColor) ?? .white }

    /// This Mac's language when OpenAI writes captions in it, otherwise English.
    static var systemLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return OpenAIRealtime.translationLanguages.contains(code) ? code : "en"
    }

    /// The language captions are translated into; nil when they stay in the spoken language.
    var translationTarget: String? {
        guard !target.isEmpty else { return nil }
        if !spoken.isEmpty, Locale(identifier: spoken).language.languageCode?.identifier == target { return nil }
        return target
    }

    /// What decides how captions are made; a change restarts running captions. Looks do not.
    var listening: [String] { [engine.rawValue, input.rawValue, target, spoken, String(showOriginal && translationTarget != nil)] }
}

extension Color {
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

/// Breaks caption text into lines that fit a width: wide characters such as Hangul and kanji
/// take about one em, others about half of one.
enum CaptionLayout {
    static func wrap(_ text: String, width: Double, size: Double) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = "", lineWidth = 0.0
            var breakAt: String.Index?
            for character in paragraph {
                let advance = em(character) * size
                if lineWidth + advance > width, !line.isEmpty {
                    if let breakAt, breakAt > line.startIndex {
                        let rest = String(line[breakAt...])
                        lines.append(String(line[..<breakAt]).trimmingCharacters(in: .whitespaces))
                        line = rest.trimmingCharacters(in: .whitespaces)
                    } else {
                        lines.append(line.trimmingCharacters(in: .whitespaces))
                        line = ""
                    }
                    lineWidth = line.reduce(0) { $0 + em($1) * size }
                    breakAt = nil
                }
                line.append(character)
                lineWidth += advance
                if character == " " { breakAt = line.endIndex }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines
    }

    static func em(_ character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first?.value else { return 0.55 }
        switch scalar {
        case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFF60: return 1.0
        case 0x20: return 0.3
        default: return character.isUppercase ? 0.66 : 0.55
        }
    }

    /// Ends a line after a sentence, so the next one starts fresh.
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!。？！…".contains(last)
    }
}

/// Live captions: hears Mac audio or the microphone and shows the words, translated, over the screen.
@MainActor
final class LiveCaptions: ObservableObject {
    @Published private(set) var isRunning = false
    /// Recent caption text, newest last; a blank line starts a new sentence.
    @Published private(set) var text = ""
    /// Recent spoken words, when the original is shown.
    @Published private(set) var spokenText = ""
    /// What is happening, shown in the captions for a moment and in the menu.
    @Published private(set) var notice: String?
    @Published private(set) var problem: String?
    @Published var moving = false
    /// How captions look and where they sit; kept in step with the settings.
    @Published var style = CaptionPreferences()
    private let speech = LiveSpeech()
    private var committed = ""
    private var volatile = ""
    private var committedSpoken = ""
    /// Whether live transcription sent text since its last finished utterance.
    private var streamedSinceFinal = false
    private var quiet: Task<Void, Never>?
    private var noticeClear: Task<Void, Never>?

    /// Where audio comes from; tests play a recording instead.
    var makeFeed: (LiveAudioInput, Double, @escaping (AVAudioPCMBuffer) -> Void, @escaping (String) -> Void) -> LiveAudioFeed {
        get { speech.makeFeed }
        set { speech.makeFeed = newValue }
    }

    func stop() {
        speech.stop()
        quiet?.cancel()
        isRunning = false; moving = false
        text = ""; spokenText = ""; committed = ""; volatile = ""; committedSpoken = ""; streamedSinceFinal = false
        notice = nil; problem = nil
    }

    /// Starts with the settings as they are now; the app restarts captions when they change.
    func start(_ preferences: CaptionPreferences, access: OpenAIAccess, codexPath: String?, keep languages: SpeechLanguages) {
        stop()
        isRunning = true
        show("Starting captions...")
        speech.start(Self.speechSettings(preferences), access: access, codexPath: codexPath, languages: languages,
                     events: { [weak self] in self?.handle($0, preferences) },
                     failed: { [weak self] in self?.problem = $0.localizedDescription })
    }

    nonisolated static func speechSettings(_ preferences: CaptionPreferences) -> LiveSpeech.Settings {
        LiveSpeech.Settings(engine: preferences.engine, input: preferences.input, spoken: preferences.spoken,
                            translation: preferences.translationTarget, spokenToo: preferences.showOriginal, settingsName: "Live Captions")
    }

    private func handle(_ event: LiveSpeech.Event, _ preferences: CaptionPreferences) {
        switch event {
        case .ready(let openAI):
            problem = nil
            let written = preferences.translationTarget.map { "in \(Locale.current.localizedString(forLanguageCode: $0) ?? $0), " } ?? ""
            show("Captions \(written)from \(preferences.input.title.lowercased()), \(openAI ? "with OpenAI" : "on this Mac")")
        case .streamed(let piece): streamedSinceFinal = true; appendStreaming(piece)
        case .finished(let utterance): finished(utterance)
        case .spoken(let piece): appendSpoken(piece)
        case .phrase(let spoken, let text, let final): heard(spoken: spoken, text: text, final: final)
        case .notice(let message): show(message)
        }
    }

    // MARK: Text

    /// A phrase from this Mac: volatile text replaces itself, final text stays.
    private func heard(spoken: String, text: String, final: Bool) {
        guard final else {
            spokenText = Self.recent(committedSpoken + spoken)
            volatile = text
            publish()
            return
        }
        volatile = ""
        if !text.isEmpty {
            committedSpoken = Self.recent(committedSpoken + spoken + " ")
            spokenText = committedSpoken
            committed += (committed.isEmpty || committed.hasSuffix("\n") ? "" : " ") + text
            if CaptionLayout.endsSentence(text) { committed += "\n" }
        }
        publish()
    }

    /// OpenAI's streamed caption text, a few characters at a time.
    private func appendStreaming(_ delta: String) {
        guard !delta.isEmpty else { return }
        committed += committed.isEmpty || committed.hasSuffix("\n") ? delta.trimmingCharacters(in: .whitespaces) : delta
        if CaptionLayout.endsSentence(delta) { committed += "\n" }
        publish()
    }

    /// A finished utterance: its text when none streamed, then a new line.
    private func finished(_ utterance: String) {
        if !streamedSinceFinal { appendStreaming(utterance) }
        streamedSinceFinal = false
        if !committed.isEmpty, !committed.hasSuffix("\n") { committed += "\n" }
        publish()
    }

    private func appendSpoken(_ delta: String) {
        spokenText = Self.recent(spokenText + delta)
        touch()
    }

    private func publish() {
        committed = Self.recent(committed)
        text = Self.recent(committed + volatile)
        touch()
    }

    /// After a few quiet seconds the captions clear, so they never cover a still picture.
    private func touch() {
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            self.committed = ""; self.volatile = ""; self.committedSpoken = ""
            self.text = ""; self.spokenText = ""
        }
    }

    /// The last few hundred characters, cut at a line or word.
    static func recent(_ text: String, limit: Int = 600) -> String {
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        if let cut = tail.firstIndex(of: "\n") ?? tail.firstIndex(of: " ") { return String(tail[tail.index(after: cut)...]) }
        return String(tail)
    }

    private func show(_ message: String) {
        notice = message
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
