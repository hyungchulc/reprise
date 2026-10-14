import AppKit
import RepriseCore
import Speech
import SwiftUI
import Translation

/// Live Captions settings: what is heard, the caption language, who makes captions, and how they look.
struct CaptionSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var captions: LiveCaptions
    @StateObject private var access = OpenAIAccessCheck()
    @StateObject private var device = OnDeviceCaptions()
    private var style: CaptionPreferences { model.preferences.captions }

    var body: some View {
        Section("Live Captions") { control }
        Section("Listening") { listening }
        if style.engine != .onDevice {
            Section("OpenAI") { OpenAIAccessRow(model: model, access: access, purpose: "Live captions") }
        }
        if style.engine != .openAI {
            Section("On This Mac") { OnDeviceCaptionStatus(device: device, style: style) }
        }
        Section("Style") { CaptionStyleSettings(model: model) }
    }

    @ViewBuilder private var control: some View {
        LabeledContent("Captions") {
            HStack(spacing: 8) {
                CaptionRunState(captions: captions)
                Button(captions.isRunning ? "Stop" : "Start") { Task { await model.toggleCaptions() } }
            }
        }
        ShortcutSettings(shortcut: model.captionsShortcut, title: "Live Captions")
        Text("Captions show over every app, also full-screen video, and clicks pass through them. Turn them on and off with the shortcut or the Reprise menu in the menu bar.")
            .repriseFont(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var listening: some View {
        Picker("Listen to", selection: $model.preferences.captions.input) {
            ForEach(LiveAudioInput.allCases) { Text($0.title).tag($0) }
        }
        Picker("Spoken language", selection: $model.preferences.captions.spoken) {
            Text("Detect automatically").tag("")
            ForEach(device.spokenLanguages(including: style.spoken)) { Text($0.name).tag($0.id) }
        }
        Picker("Captions in", selection: $model.preferences.captions.target) {
            Text("The spoken language").tag("")
            ForEach(CaptionLanguage.targets(including: style.target)) { Text($0.name).tag($0.id) }
        }
        if style.translationTarget != nil {
            Toggle("Also show the spoken words", isOn: $model.preferences.captions.showOriginal)
        }
        Picker("Captions by", selection: $model.preferences.captions.engine) {
            ForEach(CaptionEngine.allCases) { Text($0.title).tag($0) }
        }
        Text(style.engine.about).repriseFont(.caption).foregroundStyle(.secondary)
    }
}

private struct CaptionRunState: View {
    @ObservedObject var captions: LiveCaptions
    var body: some View {
        if let problem = captions.problem {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(problem).lineLimit(3)
        } else if captions.isRunning {
            Image(systemName: "captions.bubble.fill").foregroundStyle(.green)
            Text("On")
        } else {
            Text("Off").foregroundStyle(.secondary)
        }
    }
}

extension CaptionEngine {
    var about: String {
        switch self {
        case .automatic:
            "OpenAI when the account below works, and this Mac otherwise. On this Mac, the spoken language has to be chosen."
        case .openAI:
            "OpenAI recognizes the spoken language by itself and writes captions within about two seconds. Audio goes to OpenAI while captions are on."
        case .onDevice:
            "Recognition and translation run on this Mac, and nothing leaves it. This needs macOS 26 and the spoken language chosen above."
        }
    }
}

/// A language captions can be written in, as OpenAI writes them.
struct CaptionLanguage: Identifiable, Hashable {
    let id: String
    let name: String

    static func named(_ id: String) -> CaptionLanguage {
        CaptionLanguage(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id)
    }

    static func targets(including current: String) -> [CaptionLanguage] {
        var codes = OpenAIRealtime.translationLanguages
        if !current.isEmpty, !codes.contains(current) { codes.append(current) }
        return codes.map(named).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// What this Mac can do for captions: the languages it recognizes, and whether the chosen ones are ready.
@MainActor
final class OnDeviceCaptions: ObservableObject {
    enum Availability: Equatable {
        case checking
        case ready
        /// Downloads from Apple when captions start.
        case downloadsOnStart
        /// Has to be downloaded before captions start.
        case needsDownload
        case notNeeded
        case unavailable(String)
    }

    @Published private(set) var languages: [CaptionLanguage] = []
    @Published private(set) var recognition = Availability.checking
    @Published private(set) var translation = Availability.checking

    static var supported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    func spokenLanguages(including current: String) -> [CaptionLanguage] {
        guard !current.isEmpty, !languages.contains(where: { $0.id == current }) else { return languages }
        return languages + [CaptionLanguage.named(current)]
    }

    func load() async {
        guard #available(macOS 26, *), languages.isEmpty else { return }
        var ids = Set<String>()
        for locale in await SpeechTranscriber.supportedLocales { ids.insert(locale.identifier(.bcp47)) }
        for locale in await DictationTranscriber.supportedLocales { ids.insert(locale.identifier(.bcp47)) }
        languages = ids.map(CaptionLanguage.named).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func check(_ style: CaptionPreferences) async {
        guard #available(macOS 26, *), !style.spoken.isEmpty else { return }
        let locale = Locale(identifier: style.spoken)
        let name = Locale.current.localizedString(forIdentifier: style.spoken) ?? style.spoken
        recognition = await Self.recognition(locale, name: name)
        guard let target = style.translationTarget else { translation = .notNeeded; return }
        switch await LanguageAvailability().status(from: locale.language, to: Locale.Language(identifier: target)) {
        case .installed: translation = .ready
        case .supported: translation = .needsDownload
        case .unsupported: translation = .unavailable("This Mac cannot translate \(name) into \(Locale.current.localizedString(forLanguageCode: target) ?? target).")
        @unknown default: translation = .unavailable("This Mac cannot translate these languages.")
        }
    }

    @available(macOS 26, *)
    private static func recognition(_ locale: Locale, name: String) async -> Availability {
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            return await AssetInventory.status(forModules: [module]) == .installed ? .ready : .downloadsOnStart
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                              reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
            return await AssetInventory.status(forModules: [module]) == .installed ? .ready : .downloadsOnStart
        }
        return .unavailable("This Mac cannot recognize \(name). OpenAI can.")
    }
}

/// Whether captions can run on this Mac with the chosen languages, and what is missing if not.
private struct OnDeviceCaptionStatus: View {
    @ObservedObject var device: OnDeviceCaptions
    let style: CaptionPreferences

    var body: some View {
        if !OnDeviceCaptions.supported {
            Label("Captions on this Mac need macOS 26 or later. On this version, captions come from OpenAI.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        } else if style.spoken.isEmpty {
            Label("This Mac cannot detect the spoken language by itself. To caption on this Mac, choose the spoken language above.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            LabeledContent("Speech recognition") { AvailabilityText(availability: device.recognition) }
            LabeledContent("Translation") {
                HStack(spacing: 8) {
                    AvailabilityText(availability: device.translation)
                    if device.translation == .needsDownload, let target = style.translationTarget, #available(macOS 26, *) {
                        TranslationDownloadButton(source: style.spoken, target: target) { Task { await device.check(style) } }
                    }
                }
            }
        }
        Text("Speech models and translation languages download once from Apple and stay on this Mac. Translation languages are also in System Settings > General > Language & Region > Translation Languages.")
            .repriseFont(.caption).foregroundStyle(.secondary)
            .task { await device.load() }
            .task(id: style.listening) { await device.check(style) }
    }
}

private struct AvailabilityText: View {
    let availability: OnDeviceCaptions.Availability
    var body: some View {
        switch availability {
        case .checking: ProgressView().controlSize(.small)
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloadsOnStart: Text("Downloads when captions start").foregroundStyle(.secondary)
        case .needsDownload: Text("Not downloaded").foregroundStyle(.orange)
        case .notNeeded: Text("Not needed").foregroundStyle(.secondary)
        case .unavailable(let message): Text(message).foregroundStyle(.orange).lineLimit(3)
        }
    }
}

/// Asks macOS to download a translation pair; macOS shows its own confirmation.
@available(macOS 26, *)
private struct TranslationDownloadButton: View {
    let source: String
    let target: String
    let finished: () -> Void
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        Button("Download") {
            configuration = TranslationSession.Configuration(source: Locale(identifier: source).language, target: Locale.Language(identifier: target))
        }
        .translationTask(configuration) { session in
            try? await session.prepareTranslation()
            finished()
        }
    }
}

/// How captions look, with a preview.
private struct CaptionStyleSettings: View {
    @ObservedObject var model: AppModel
    private var style: CaptionPreferences { model.preferences.captions }

    var body: some View {
        CaptionPreview(style: style)
        LabeledContent("Text size") {
            HStack {
                Slider(value: $model.preferences.captions.textSize, in: 16...64, step: 2)
                Text("\(Int(style.textSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
        ColorPicker("Text color", selection: textColor, supportsOpacity: false)
        LabeledContent("Background") {
            HStack {
                Slider(value: $model.preferences.captions.backgroundOpacity, in: 0...0.9, step: 0.05)
                Text(style.backgroundOpacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
        Stepper("Lines: \(style.lines)", value: $model.preferences.captions.lines, in: 1...4)
        Picker("Position", selection: $model.preferences.captions.position) {
            ForEach(positions) { Text($0.title).tag($0) }
        }
        HStack {
            Text("Drag the captions anywhere, such as below a video.").repriseFont(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Move Captions...") { model.moveCaptions() }
        }
    }

    private var textColor: Binding<Color> {
        Binding(get: { model.preferences.captions.color }, set: { model.preferences.captions.textColor = $0.hex })
    }

    /// "Where I moved it" once the captions have been moved.
    private var positions: [CaptionPosition] {
        style.center == nil && style.position != .custom ? [.bottom, .top] : CaptionPosition.allCases
    }
}

/// Sample captions over a dark picture, in the chosen language and style.
private struct CaptionPreview: View {
    let style: CaptionPreferences
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(white: 0.36), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                CaptionBlock(text: Self.sample(style.translationTarget ?? style.target), spoken: Self.sample(style.target == "sv" ? "en" : "sv"),
                             style: style, width: proxy.size.width - 24)
                    .padding(.bottom, 12)
            }
        }
        .frame(height: style.textSize * 1.3 * Double(style.lines) + (style.showOriginal ? style.textSize : 0) + 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Caption preview")
    }

    static func sample(_ language: String) -> String {
        let samples = [
            "en": "Today we're baking cinnamon buns at home.",
            "ko": "오늘은 집에서 시나몬 롤을 구워 볼게요.",
            "ja": "今日は家でシナモンロールを焼きます。",
            "zh": "今天我们在家烤肉桂卷。",
            "sv": "I dag bakar vi kanelbullar hemma.",
            "de": "Heute backen wir zu Hause Zimtschnecken.",
            "fr": "Aujourd'hui, on fait des brioches à la cannelle.",
            "es": "Hoy horneamos rollos de canela en casa."
        ]
        let code = Locale(identifier: language).language.languageCode?.identifier ?? language
        return samples[code] ?? samples["en"]!
    }
}
