import AppKit
@preconcurrency import AVFoundation
import RepriseCore
import Speech
import SwiftUI
import Translation

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
    private var committed = ""
    private var volatile = ""
    /// Whether live transcription sent text since its last finished utterance.
    private var streamedSinceFinal = false
    private var run: Task<Void, Never>?
    private var source: LiveAudioFeed?
    /// Where audio comes from: the chosen input at a sample rate, delivering buffers or a failure.
    var makeFeed: (LiveAudioInput, Double, @escaping (AVAudioPCMBuffer) -> Void, @escaping (String) -> Void) -> LiveAudioFeed = {
        LiveAudioSource($0, sampleRate: $1, deliver: $2, failed: $3)
    }
    private var quiet: Task<Void, Never>?
    private var noticeClear: Task<Void, Never>?

    func stop() {
        run?.cancel(); run = nil
        source?.stop(); source = nil
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
        run = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.choose(preferences, access: access, codexPath: codexPath, languages: languages)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.problem = error.localizedDescription
                self.source?.stop(); self.source = nil
            }
        }
    }

    /// OpenAI when it is chosen or works; this Mac otherwise, when it knows the spoken language. With
    /// Automatic, captions also move to this Mac when OpenAI stops working, such as offline.
    private func choose(_ preferences: CaptionPreferences, access: OpenAIAccess, codexPath: String?, languages: SpeechLanguages) async throws {
        var openAIFailure: Error?
        if preferences.engine != .onDevice {
            do {
                let credential = try await OpenAICredential.resolve(access, codexPath: codexPath)
                try await runOpenAI(preferences, credential: credential, access: access, codexPath: codexPath)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as SystemAudioFailure {
                // No audio to listen to; this Mac would hear none either.
                throw failure
            } catch {
                guard preferences.engine == .automatic else { throw error }
                openAIFailure = error
            }
        }
        let reason = openAIFailure.map { "OpenAI is unavailable: \($0.localizedDescription) " } ?? ""
        guard #available(macOS 26, *) else { throw CaptionFailure(reason + "Captions on this Mac need macOS 26 or later.") }
        guard !preferences.spoken.isEmpty else {
            throw CaptionFailure(reason + "To caption on this Mac, choose the spoken language in Live Captions settings.")
        }
        if openAIFailure != nil { show("OpenAI is unavailable, so captions run on this Mac.") }
        languages.alsoKept = [preferences.spoken]
        try await runOnDevice(preferences)
    }

    // MARK: OpenAI

    /// What OpenAI is asked for: live translation into the caption language or, when captions stay
    /// in the spoken language, live transcription.
    nonisolated static func openAISession(_ preferences: CaptionPreferences) -> (session: [String: Any], translation: Bool) {
        if let target = preferences.translationTarget {
            return (OpenAIRealtime.translationSession(language: target, transcribeInput: preferences.showOriginal), true)
        }
        let spoken = preferences.spoken.isEmpty ? nil : Locale(identifier: preferences.spoken).language.languageCode?.identifier
        return (OpenAIRealtime.transcriptionSession(model: OpenAIRealtime.liveTranscriptionModel, language: spoken, vad: false), false)
    }

    /// One OpenAI event, as captions use it.
    enum OpenAIEvent: Equatable {
        case ready
        /// Translated caption text, a few characters at a time.
        case caption(String)
        /// The spoken words beside a translation.
        case spoken(String)
        /// Live transcription in the spoken language, a few characters at a time; a model that
        /// finishes utterances also sends each one whole.
        case partial(String)
        case final(String)
        case failure(String, code: String)
        case other
    }

    nonisolated static func openAIEvent(_ event: [String: Any]) -> OpenAIEvent {
        switch event["type"] as? String {
        case "session.created": return .ready
        case "session.output_transcript.delta": return .caption(event["delta"] as? String ?? "")
        case "session.input_transcript.delta": return .spoken(event["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.delta": return .partial(event["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed": return .final(event["transcript"] as? String ?? "")
        case "error":
            let error = event["error"] as? [String: Any] ?? [:]
            return .failure(error["message"] as? String ?? "an error occurred", code: error["code"] as? String ?? "error")
        default: return .other
        }
    }

    private func runOpenAI(_ preferences: CaptionPreferences, credential first: OpenAICredential, access: OpenAIAccess, codexPath: String?) async throws {
        let (session, translation) = Self.openAISession(preferences)
        let (audio, feed) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(100))
        let source = makeFeed(preferences.input, 24_000, { buffer in
            guard let samples = buffer.floatChannelData?[0] else { return }
            feed.yield(OpenAIRealtime.pcm16(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
        }, { [weak self] message in Task { @MainActor in self?.problem = message } })
        try await source.start()
        self.source = source
        let link = SocketLink()
        let append = translation ? "session.input_audio_buffer.append" : "input_audio_buffer.append"
        // One sender for the whole run; while a session reconnects, the last two seconds wait.
        let sender = Task.detached {
            var pending = Data()
            for await chunk in audio {
                pending.append(chunk)
                guard let socket = link.socket else {
                    if pending.count > 96_000 { pending.removeFirst(pending.count - 96_000) }
                    continue
                }
                guard pending.count >= 4_800 else { continue }
                try? await socket.send(["type": append, "audio": pending.base64EncodedString()])
                pending.removeAll(keepingCapacity: true)
            }
        }
        defer { sender.cancel(); feed.finish(); source.stop() }
        let written = preferences.translationTarget.map { "in \(Locale.current.localizedString(forLanguageCode: $0) ?? $0), " } ?? ""
        var credential: OpenAICredential? = first
        var failures = 0
        while !Task.isCancelled {
            let opened = Date()
            do {
                // A session ends after a time limit or a dropped connection; the next asks for a fresh sign-in.
                let current: OpenAICredential
                if let credential { current = credential } else { current = try await OpenAICredential.resolve(access, codexPath: codexPath) }
                credential = nil
                let secret = try await OpenAIRealtime.clientSecret(current, session: session, translation: translation)
                let socket = OpenAIRealtime.connect(secret: secret, translation: translation)
                defer { link.socket = nil; socket.close() }
                for try await event in socket.events {
                    switch Self.openAIEvent(event) {
                    case .ready:
                        link.socket = socket; failures = 0; problem = nil
                        show("Captions \(written)from \(preferences.input.title.lowercased()), with OpenAI")
                    case .caption(let delta): appendStreaming(delta)
                    case .spoken(let delta): appendSpoken(delta)
                    case .partial(let delta): streamedSinceFinal = true; appendStreaming(delta)
                    case .final(let text): finished(text)
                    case .failure(let message, let code): throw OpenAIRealtime.Failure("OpenAI captions: \(message)", code: code)
                    case .other: break
                    }
                }
                // OpenAI ended the session; one that lasted is followed by the next at once.
                if Date().timeIntervalSince(opened) < 20 { throw CaptionFailure("OpenAI ended the captions session.") }
            } catch let failure as OpenAIRealtime.Failure where failure.code == "unauthorized" || failure.code == "rate_limit" {
                throw failure
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                guard failures <= 3 else { throw error }
                show("Reconnecting to OpenAI...")
                try await Task.sleep(for: .seconds(Double(failures)))
            }
        }
    }

    // MARK: On this Mac

    @available(macOS 26, *)
    private func runOnDevice(_ preferences: CaptionPreferences) async throws {
        let locale = Locale(identifier: preferences.spoken)
        let name = Locale.current.localizedString(forIdentifier: preferences.spoken) ?? preferences.spoken
        let source = locale.language
        let target = preferences.target.isEmpty ? nil : Locale.Language(identifier: preferences.target)
        var translator: CaptionTranslator?
        if let target, target.languageCode != source.languageCode {
            let status = await LanguageAvailability().status(from: source, to: target)
            guard status == .installed else {
                throw CaptionFailure(status == .unsupported
                    ? "This Mac cannot translate \(name) into \(Locale.current.localizedString(forLanguageCode: preferences.target) ?? preferences.target). Choose OpenAI, or another language."
                    : "Download \(name) and \(Locale.current.localizedString(forLanguageCode: preferences.target) ?? preferences.target) for translation in Live Captions settings first.")
            }
            translator = CaptionTranslator(from: source, to: target)
        }
        let translate: (String) async -> String = { [weak self] text in
            guard let translator else { return text }
            if let translated = await translator.translate(text) { return translated }
            self?.show("This Mac could not translate that part, so it shows as spoken.")
            return text
        }
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            try await analyze(module, locale: supported, input: preferences.input, name: name) {
                for try await result in module.results { await self.heard(String(result.text.characters), final: result.isFinal, translate: translate) }
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                              reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
            try await analyze(module, locale: supported, input: preferences.input, name: name) {
                for try await result in module.results { await self.heard(String(result.text.characters), final: result.isFinal, translate: translate) }
            }
        } else {
            throw CaptionFailure("This Mac cannot recognize \(name). Choose OpenAI in Live Captions settings, which recognizes the language by itself.")
        }
    }

    /// Runs the analyzer on live audio until captions stop, after the model for `locale` is installed.
    @available(macOS 26, *)
    private func analyze(_ module: any SpeechModule, locale: Locale, input: LiveAudioInput, name: String,
                         results: @escaping () async throws -> Void) async throws {
        if await AssetInventory.status(forModules: [module]) != .installed {
            show("Downloading the speech model for \(name)...")
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await request.downloadAndInstall() }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CaptionFailure("The speech model for \(name) takes no audio format this Mac has.")
        }
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(200))
        let converter = BufferConverter(to: format)
        let source = makeFeed(input, format.sampleRate, { buffer in
            if let converted = converter.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
        }, { [weak self] message in Task { @MainActor in self?.problem = message } })
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.start(inputSequence: inputs)
        try await source.start()
        self.source = source
        show("Captions from \(input.title.lowercased()), \(name), on this Mac")
        defer { feed.finish(); source.stop() }
        try await withTaskCancellationHandler {
            try await results()
        } onCancel: {
            feed.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    // MARK: Text

    /// A recognized phrase on this Mac: volatile text replaces itself, final text stays.
    private var translationGeneration = 0
    private func heard(_ phrase: String, final: Bool, translate: @escaping (String) async -> String) async {
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        translationGeneration += 1
        let generation = translationGeneration
        if final {
            volatile = ""
            guard !phrase.isEmpty else { return }
            appendSpokenLine(phrase)
            let translated = await translate(phrase)
            committed += (committed.isEmpty || committed.hasSuffix("\n") ? "" : " ") + translated
            if CaptionLayout.endsSentence(translated) { committed += "\n" }
            publish()
        } else {
            spokenText = Self.recent(committedSpoken + phrase)
            let translated = await translate(phrase)
            guard generation == translationGeneration else { return }
            volatile = translated
            publish()
        }
    }

    private var committedSpoken = ""
    private func appendSpokenLine(_ phrase: String) {
        committedSpoken = Self.recent(committedSpoken + phrase + " ")
        spokenText = committedSpoken
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

struct CaptionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The socket audio goes to; nil while a session connects.
private final class SocketLink: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RealtimeSocket?
    var socket: RealtimeSocket? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Translation on this Mac: the low-latency model where it covers the languages, the standard one otherwise.
@available(macOS 26, *)
@MainActor
private final class CaptionTranslator {
    private let source: Locale.Language
    private let target: Locale.Language
    private var session: TranslationSession
    private var lowLatency = false

    init(from source: Locale.Language, to target: Locale.Language) {
        self.source = source
        self.target = target
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
            lowLatency = true
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    }

    func translate(_ text: String) async -> String? {
        do {
            return try await session.translate(text).targetText
        } catch where lowLatency {
            // The low-latency model knows fewer languages, such as no Swedish in macOS 26.4.
            lowLatency = false
            session = TranslationSession(installedSource: source, target: target)
            return try? await session.translate(text).targetText
        } catch {
            return nil
        }
    }
}

/// Converts float buffers to the analyzer's format.
final class BufferConverter: @unchecked Sendable {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?
    init(to format: AVAudioFormat) { self.format = format }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if from != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format); from = buffer.format }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
