import AppKit
@preconcurrency import AVFoundation
import RepriseCore
import Speech
import Translation

/// Live speech from one input as text, in the spoken language or translated. OpenAI streams text a
/// few characters at a time; this Mac sends phrases that settle. Live captions and the meeting
/// assistant listen through it.
@MainActor
final class LiveSpeech {
    struct Settings: Equatable {
        var engine = CaptionEngine.automatic
        var input = LiveAudioInput.system
        /// The spoken language as a BCP 47 identifier. This Mac needs it; OpenAI recognizes the language itself.
        var spoken = ""
        /// The language to translate into; nil keeps the spoken language.
        var translation: String?
        /// With a translation, OpenAI sends the spoken words too.
        var spokenToo = false
        /// The settings page where these are chosen, named in messages.
        var settingsName = "Live Captions"
        /// Whether OpenAI hears the spoken language as a hint; a language taken from elsewhere only guides this Mac.
        var hintsOpenAI = true
    }

    enum Event: Equatable {
        /// Listening started, with OpenAI or on this Mac.
        case ready(openAI: Bool)
        /// Text that only grows, a few characters at a time.
        case streamed(String)
        /// A whole utterance, from a model that finishes them.
        case finished(String)
        /// The spoken words beside a translation, a few characters at a time.
        case spoken(String)
        /// A phrase from this Mac, replaced by the next until it is final; `text` is translated when asked.
        case phrase(spoken: String, text: String, final: Bool)
        case notice(String)
    }

    /// Where audio comes from: the chosen input at a sample rate, delivering buffers or a failure.
    var makeFeed: (LiveAudioInput, Double, @escaping (AVAudioPCMBuffer) -> Void, @escaping (String) -> Void) -> LiveAudioFeed = {
        LiveAudioSource($0, sampleRate: $1, deliver: $2, failed: $3)
    }
    private var run: Task<Void, Never>?
    private var source: LiveAudioFeed?
    private var events: (Event) -> Void = { _ in }
    private var failed: (Error) -> Void = { _ in }

    func start(_ settings: Settings, access: OpenAIAccess, codexPath: String?, languages: SpeechLanguages,
               events: @escaping (Event) -> Void, failed: @escaping (Error) -> Void) {
        stop()
        self.events = events
        self.failed = failed
        run = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.choose(settings, access: access, codexPath: codexPath, languages: languages)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.source?.stop(); self.source = nil
                self.failed(error)
            }
        }
    }

    /// Stops listening; nothing more is sent after this.
    func stop() {
        run?.cancel(); run = nil
        source?.stop(); source = nil
        events = { _ in }; failed = { _ in }
    }

    /// The audio stopped, such as when macOS ends the stream; listening cannot go on.
    private func lost(_ message: String) {
        run?.cancel(); run = nil
        source?.stop(); source = nil
        failed(CaptionFailure(message))
    }

    /// OpenAI when it is chosen or works; this Mac otherwise, when it knows the spoken language. With
    /// Automatic, listening also moves to this Mac when OpenAI stops working, such as offline.
    private func choose(_ settings: Settings, access: OpenAIAccess, codexPath: String?, languages: SpeechLanguages) async throws {
        var openAIFailure: Error?
        if settings.engine != .onDevice {
            do {
                let credential = try await OpenAICredential.resolve(access, codexPath: codexPath)
                try await runOpenAI(settings, credential: credential, access: access, codexPath: codexPath)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as SystemAudioFailure {
                // No audio to listen to; this Mac would hear none either.
                throw failure
            } catch {
                guard settings.engine == .automatic else { throw error }
                openAIFailure = error
            }
        }
        let reason = openAIFailure.map { "OpenAI is unavailable: \($0.localizedDescription) " } ?? ""
        guard #available(macOS 26, *) else { throw CaptionFailure(reason + "Listening on this Mac needs macOS 26 or later.") }
        guard !settings.spoken.isEmpty else {
            throw CaptionFailure(reason + "To listen on this Mac, choose the spoken language in \(settings.settingsName) settings.")
        }
        if openAIFailure != nil { events(.notice("OpenAI is unavailable, so this Mac listens instead.")) }
        languages.alsoKept.insert(settings.spoken)
        try await runOnDevice(settings)
    }

    // MARK: OpenAI

    /// What OpenAI is asked for: live translation, or live transcription in the spoken language.
    nonisolated static func openAISession(_ settings: Settings) -> (session: [String: Any], translation: Bool) {
        if let target = settings.translation {
            return (OpenAIRealtime.translationSession(language: target, transcribeInput: settings.spokenToo), true)
        }
        let spoken = settings.spoken.isEmpty || !settings.hintsOpenAI ? nil : Locale(identifier: settings.spoken).language.languageCode?.identifier
        return (OpenAIRealtime.transcriptionSession(model: OpenAIRealtime.liveTranscriptionModel, language: spoken, vad: false), false)
    }

    /// One OpenAI event, as listeners use it.
    enum OpenAIEvent: Equatable {
        case ready
        /// Translated text, a few characters at a time.
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

    private func runOpenAI(_ settings: Settings, credential first: OpenAICredential, access: OpenAIAccess, codexPath: String?) async throws {
        let (session, translation) = Self.openAISession(settings)
        let (audio, feed) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(100))
        let source = makeFeed(settings.input, 24_000, { buffer in
            guard let samples = buffer.floatChannelData?[0] else { return }
            feed.yield(OpenAIRealtime.pcm16(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
        }, { [weak self] message in Task { @MainActor in self?.lost(message) } })
        try await source.start()
        self.source = source
        let link = SocketLink()
        let append = translation ? "session.input_audio_buffer.append" : "input_audio_buffer.append"
        // One sender for the whole run; while a session connects, the last two seconds wait.
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
                        link.socket = socket; failures = 0
                        events(.ready(openAI: true))
                    case .caption(let delta), .partial(let delta): if !delta.isEmpty { events(.streamed(delta)) }
                    case .spoken(let delta): if !delta.isEmpty { events(.spoken(delta)) }
                    case .final(let text): events(.finished(text))
                    case .failure(let message, let code): throw OpenAIRealtime.Failure("OpenAI: \(message)", code: code)
                    case .other: break
                    }
                }
                // OpenAI ended the session; one that lasted is followed by the next at once.
                if Date().timeIntervalSince(opened) < 20 { throw CaptionFailure("OpenAI ended the session.") }
            } catch let failure as OpenAIRealtime.Failure where failure.code == "unauthorized" || failure.code == "rate_limit" {
                throw failure
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                guard failures <= 3 else { throw error }
                events(.notice("Reconnecting to OpenAI..."))
                try await Task.sleep(for: .seconds(Double(failures)))
            }
        }
    }

    // MARK: On this Mac

    @available(macOS 26, *)
    private func runOnDevice(_ settings: Settings) async throws {
        let locale = Locale(identifier: settings.spoken)
        let name = Locale.current.localizedString(forIdentifier: settings.spoken) ?? settings.spoken
        var translator: CaptionTranslator?
        if let code = settings.translation, Locale.Language(identifier: code).languageCode != locale.language.languageCode {
            let target = Locale.Language(identifier: code)
            let targetName = Locale.current.localizedString(forLanguageCode: code) ?? code
            let status = await LanguageAvailability().status(from: locale.language, to: target)
            guard status == .installed else {
                throw CaptionFailure(status == .unsupported
                    ? "This Mac cannot translate \(name) into \(targetName). Choose OpenAI, or another language."
                    : "Download \(name) and \(targetName) for translation in \(settings.settingsName) settings first.")
            }
            translator = CaptionTranslator(from: locale.language, to: target)
        }
        let heard: (String, Bool) async -> Void = { [weak self] phrase, final in await self?.heard(phrase, final: final, translator: translator) }
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            try await analyze(module, locale: supported, input: settings.input, name: name) {
                for try await result in module.results { await heard(String(result.text.characters), result.isFinal) }
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                              reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
            try await analyze(module, locale: supported, input: settings.input, name: name) {
                for try await result in module.results { await heard(String(result.text.characters), result.isFinal) }
            }
        } else {
            throw CaptionFailure("This Mac cannot recognize \(name). Choose OpenAI in \(settings.settingsName) settings, which recognizes the language by itself.")
        }
    }

    /// A recognized phrase, translated when asked. Results arrive one at a time, so the phrases stay in order.
    @available(macOS 26, *)
    private func heard(_ phrase: String, final: Bool, translator: CaptionTranslator?) async {
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        guard let translator, !phrase.isEmpty else { events(.phrase(spoken: phrase, text: phrase, final: final)); return }
        if let translated = await translator.translate(phrase) {
            events(.phrase(spoken: phrase, text: translated, final: final))
        } else {
            events(.notice("This Mac could not translate that part, so it shows as spoken."))
            events(.phrase(spoken: phrase, text: phrase, final: final))
        }
    }

    /// Runs the analyzer on live audio until listening stops, after the model for `locale` is installed.
    @available(macOS 26, *)
    private func analyze(_ module: any SpeechModule, locale: Locale, input: LiveAudioInput, name: String,
                         results: @escaping () async throws -> Void) async throws {
        if await AssetInventory.status(forModules: [module]) != .installed {
            events(.notice("Downloading the speech model for \(name)..."))
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
        }, { [weak self] message in Task { @MainActor in self?.lost(message) } })
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.start(inputSequence: inputs)
        try await source.start()
        self.source = source
        events(.ready(openAI: false))
        defer { feed.finish(); source.stop() }
        try await withTaskCancellationHandler {
            try await results()
        } onCancel: {
            feed.finish()
            Task { await analyzer.cancelAndFinishNow() }
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
