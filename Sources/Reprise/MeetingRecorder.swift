import AppKit
import AVFoundation
import Combine
import Speech
import CoreGraphics
import RepriseCore
import WhisperKit

@MainActor
final class MeetingRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Not recording"
    @Published private(set) var lastError: String?
    @Published private(set) var transcript = ""
    @Published private(set) var systemAudioAvailable = false
    @Published private(set) var isBusy = false
    @Published private(set) var transcribingMomentID: String?
    private var transcribingPath: String?
    @Published private(set) var lastSavedMoment: Moment?

    private let store: MomentStore
    private let root: URL
    private var recorder: AVAudioRecorder?
    private var systemRecorder: SystemAudioRecorder?
    private var systemURL: URL?
    private var startupTask: Task<Void, Never>?
    private var generation = UUID()
    private var starting = false
    private var recordingLimit: Task<Void, Never>?
    private var startedAt: Date?
    private var title = "Meeting"
    private var relativePath: String?
    private var finalizing = false
    private var speechTask: SFSpeechRecognitionTask?
    private var speechTimeout: Task<Void, Never>?
    private struct SpeechChunk {
        var pieces: [RecognizedSpeech] = []
    }
    private var speechContinuation: CheckedContinuation<SpeechChunk, Never>?
    private var speechGeneration = UUID()
    private var speechChunk = SpeechChunk()
    private var transcriptSegments: [TranscriptSegment] = []
    private var transcriptionWarnings: [String] = []
    private var transcriptionCancelled = false
    private var transcriptionEnabled = true
    private var transcription = TranscriptionRequest()
    /// While speakers are being labeled, Apple's phrases stay apart until each has its speaker.
    private var phraseRows = false
    private var analysisCancel: (() async -> Void)?
    private var analysisReached: [String: Double] = [:]
    private var observers: [NSObjectProtocol] = []
    private let languages: SpeechLanguages
    private let speechModels: LocalSpeechModels

    init(store: MomentStore, root: URL, languages: SpeechLanguages, speechModels: LocalSpeechModels) {
        self.store = store
        self.root = root
        self.languages = languages
        self.speechModels = speechModels
        super.init()
        // A suspended machine must not silently resume its microphone session on wake.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.cancelTranscription()
                    await self?.stop()
                }
            })
        }
    }

    deinit {
        recorder?.stop()
        startupTask?.cancel()
        recordingLimit?.cancel()
        speechTask?.cancel()
        speechTimeout?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func start(title: String = "Meeting", includeSystemAudio: Bool = true, transcribe: Bool = true, request: TranscriptionRequest) async {
        guard !isRecording, !starting, !finalizing else { return }
        transcriptionEnabled = transcribe
        transcription = request
        starting = true
        isBusy = true
        generation = UUID()
        let token = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.beginRecording(title: title, includeSystemAudio: includeSystemAudio, token: token)
        }
        startupTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == token || !starting { startupTask = nil }
    }

    private func beginRecording(title: String, includeSystemAudio: Bool, token: UUID) async {
        defer { starting = false; isBusy = false }
        lastError = nil
        lastSavedMoment = nil
        transcriptionCancelled = false
        systemAudioAvailable = false
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            lastError = "Allow microphone access before starting a meeting."
            status = "Microphone permission required"
            return
        }
        let directory = root.appendingPathComponent("meetings", isDirectory: true)
        let id = UUID().uuidString
        let path = "meetings/\(id).mic.m4a"
        let systemFile = directory.appendingPathComponent("\(id).system.m4a")
        var capture: SystemAudioRecorder?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let recording = try AVAudioRecorder(url: root.appendingPathComponent(path), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
            recording.delegate = self
            guard recording.prepareToRecord() else { throw CaptureFailure("Unable to prepare microphone recording.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recording.url.path)
            // A finite ceiling also bounds accidental unattended disk growth.
            let origin = CMClockGetTime(CMClockGetHostTimeClock())
            guard recording.record(forDuration: 4 * 60 * 60) else { throw CaptureFailure("Unable to start microphone recording.") }
            self.recorder = recording
            status = "Starting meeting audio"
            if includeSystemAudio {
                if CGPreflightScreenCaptureAccess() {
                    do {
                        let system = try SystemAudioRecorder(url: systemFile, origin: origin) { [weak self] message in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.lastError = "System audio: \(message)"
                                self.systemAudioAvailable = false
                                if self.isRecording { await self.stop() }
                            }
                        }
                        capture = system
                        try await system.start()
                        try Task.checkCancellation()
                        systemAudioAvailable = true
                    } catch {
                        if let capture { _ = await capture.stop() }
                        capture = nil
                        try? FileManager.default.removeItem(at: systemFile)
                        lastError = "Microphone only. System audio: \(error.localizedDescription)"
                    }
                } else {
                    lastError = "Microphone only. Allow Screen Recording to include system audio."
                }
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            self.systemRecorder = capture
            self.systemURL = capture == nil ? nil : systemFile
            self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting" : title
            relativePath = path
            startedAt = Date().addingTimeInterval(-recording.currentTime)
            transcript = ""
            transcriptSegments = []
            isRecording = true
            status = systemAudioAvailable ? "Recording microphone and system audio" : (includeSystemAudio ? "Recording microphone only" : "Recording microphone")
            recordingLimit = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, 4 * 60 * 60 - recording.currentTime))) } catch { return }
                guard let self, self.generation == token, self.isRecording else { return }
                self.recordingLimit = nil
                await self.stop()
            }
        } catch {
            self.recorder?.stop()
            self.recorder = nil
            if let capture { _ = await capture.stop() }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
            try? FileManager.default.removeItem(at: systemFile)
            systemAudioAvailable = false
            if error is CancellationError { status = "Not recording" }
            else { lastError = error.localizedDescription; status = "Recording unavailable" }
        }
    }

    func stop() async {
        if starting {
            generation = UUID()
            recorder?.stop()
            let task = startupTask
            task?.cancel()
            await task?.value
            return
        }
        guard !finalizing, let recorder, let path = relativePath else { return }
        finalizing = true
        isBusy = true
        isRecording = false
        recordingLimit?.cancel()
        recordingLimit = nil
        recorder.stop()
        self.recorder = nil
        relativePath = nil
        let system = systemRecorder
        let systemFile = systemURL
        systemRecorder = nil
        systemURL = nil
        systemAudioAvailable = false
        defer { finalizing = false; isBusy = false }
        var savedPath = path
        var url = root.appendingPathComponent(path)
        let timestamp = startedAt ?? Date()
        startedAt = nil
        status = "Saving meeting"
        do {
            if let system {
                let result = await system.stop()
                if let warning = result.warning { appendWarning("System audio: \(warning)") }
                if let systemAudio = result.url {
                    let mixedPath = path.replacingOccurrences(of: ".mic.m4a", with: ".m4a")
                    let mixedURL = root.appendingPathComponent(mixedPath)
                    do {
                        try await SystemAudioMedia.mix(microphone: url, system: systemAudio, systemOffset: result.offset, destination: mixedURL)
                        try? FileManager.default.removeItem(at: url)
                        try? FileManager.default.removeItem(at: systemAudio)
                        savedPath = mixedPath
                        url = mixedURL
                    } catch {
                        // Keep both sources for recovery if the combined export fails.
                        _ = try? store.cipher.sealFile(at: systemAudio)
                        appendWarning("Saved microphone only. Mixing failed: \(error.localizedDescription). System audio retained at \(systemAudio.lastPathComponent).")
                    }
                } else if let systemFile {
                    try? FileManager.default.removeItem(at: systemFile)
                    appendWarning("Saved microphone only.")
                }
            }
            let recorded = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard recorded > 0 else { throw CaptureFailure("The microphone recording is empty.") }
            let savedAsset = AVURLAsset(url: url)
            let savedDuration = try await savedAsset.load(.duration).seconds
            guard savedDuration.isFinite, savedDuration > 0,
                  !(try await savedAsset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw CaptureFailure("The meeting audio is not playable.")
            }
            // Sealed before it is indexed; transcription reads the sealed file.
            try store.cipher.sealFile(at: url)
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? recorded
            // Index the complete audio before transcription, so interruption cannot hide it.
            let moment = Moment(timestamp: timestamp, appName: "Meeting", windowTitle: title,
                                videoPath: savedPath, kind: "meeting", byteCount: bytes, audioDuration: savedDuration,
                                transcriptionNote: transcriptionEnabled ? "Transcription has not completed." : "Automatic transcription is off.")
            try await store.insert(moment)
            lastSavedMoment = moment
            if transcriptionEnabled { await transcribeStoredAudio(moment, url: url, request: transcription) }
            status = lastError != nil ? "Meeting saved with warnings" : (transcript.isEmpty ? "Meeting saved, no transcript available" : "Meeting saved")
        } catch {
            // Keep the original audio recoverable when indexing fails, sealed like the rest.
            _ = try? store.cipher.sealFile(at: url)
            appendWarning("\(error.localizedDescription) Audio retained at \(savedPath).")
            status = "Meeting could not be indexed"
        }
    }

    /// Library files a recording or transcription in progress is still using.
    var mediaInUse: Set<String> {
        var paths = Set([transcribingPath].compactMap { $0 })
        if let relativePath { paths.formUnion([relativePath, relativePath.replacingOccurrences(of: ".mic.m4a", with: ".m4a")]) }
        if let systemURL { paths.insert("meetings/" + systemURL.lastPathComponent) }
        return paths
    }

    func transcribeSaved(_ moment: Moment, request: TranscriptionRequest) async {
        guard !isRecording, !isBusy, !starting, !finalizing, moment.kind == "meeting", let path = moment.videoPath else { return }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.isReadableFile(atPath: url.path) else {
            lastError = "The original audio file is unavailable."; return
        }
        isBusy = true; finalizing = true; lastError = nil; transcriptionCancelled = false
        defer { isBusy = false; finalizing = false }
        await transcribeStoredAudio(moment, url: url, request: request)
        status = lastError == nil ? "Transcript saved" : "Transcription needs attention"
    }

    private func transcribeStoredAudio(_ moment: Moment, url: URL, request: TranscriptionRequest) async {
        transcribingMomentID = moment.id; transcribingPath = moment.videoPath
        defer { transcribingMomentID = nil; transcribingPath = nil }
        transcript = ""; transcriptSegments = []; transcriptionWarnings = []
        if transcriptionCancelled {
            appendTranscriptionWarning("Transcription was interrupted. Complete audio was kept.")
        } else {
            phraseRows = request.speakerLabels
            defer { phraseRows = false }
            switch request.engine {
            case .openAI: await transcribeWithOpenAI(url, request: request)
            case .whisperKit: await transcribeWithWhisper(url, request: request)
            case .apple: await transcribeOnDevice(url, locales: request.locales)
            }
            if request.speakerLabels, !transcriptSegments.isEmpty {
                if !transcriptionCancelled { await labelSpeakers(url) }
                transcriptSegments = TranscriptMerge.rows(transcriptSegments)
            }
            if !transcriptSegments.isEmpty { transcript = SpeakerLabels.text(transcriptSegments) }
            await speechModels.unload()
        }
        do {
            let note = transcriptionWarnings.isEmpty ? nil : transcriptionWarnings.joined(separator: " ")
            try await store.updateTranscript(id: moment.id, text: transcript.isEmpty ? moment.text : transcript,
                segments: transcript.isEmpty ? (moment.transcriptSegments ?? []) : transcriptSegments, note: note)
            lastSavedMoment = try await store.moment(id: moment.id)
        } catch { appendWarning("Could not save transcript: \(error.localizedDescription)") }
    }

    /// Apple's speech models on this Mac, in every chosen language. The other engines fall back to it.
    private func transcribeOnDevice(_ url: URL, locales selection: [String]) async {
        transcriptSegments = []; transcript = ""
        guard !selection.isEmpty else {
            appendTranscriptionWarning("Choose at least one transcription language in Audio settings.")
            return
        }
        status = "Preparing on-device speech models"
        let prepared = await languages.prepare(selection)
        for note in prepared.notes { appendTranscriptionWarning(note) }
        let names = prepared.locales.map { languages.name(for: $0.identifier(.bcp47)) }.joined(separator: ", ")
        if prepared.locales.isEmpty || transcriptionCancelled {
            if prepared.locales.isEmpty { appendTranscriptionWarning("No transcription language is ready on this Mac. Check Audio settings.") }
        } else if #available(macOS 26, *), SpeechLanguages.usesSpeechAnalyzer {
            await analyze(url, locales: prepared.locales)
        } else if SFSpeechRecognizer.authorizationStatus() != .authorized {
            appendTranscriptionWarning("Speech Recognition permission is not allowed. Enable it in Privacy settings to transcribe this recording.")
        } else {
            await transcribeChunks(url, locales: prepared.locales)
        }
        if transcript.isEmpty, transcriptionWarnings.isEmpty, !names.isEmpty {
            appendTranscriptionWarning("No speech was recognized in \(names).")
        }
    }

    /// OpenAI's models through the ChatGPT sign-in or API key. Without either, or when OpenAI
    /// fails, the recording is transcribed on this Mac instead.
    private func transcribeWithOpenAI(_ url: URL, request: TranscriptionRequest) async {
        let name = OpenAITranscriptionModel.named(request.openAIModel)
        status = "Connecting to OpenAI"
        do {
            let credential = try await OpenAICredential.resolve(request.openAIAccess, codexPath: request.codexPath)
            let audio = try await RecordingPCM(url: url, cipher: store.cipher, sampleRate: 24_000)
            let duration = Int(audio.duration)
            status = "Transcribing with \(name), 0 / \(duration) seconds"
            let transcriber = CloudTranscriber(credential: credential, model: request.openAIModel, language: request.languageHint)
            let report: @Sendable (Double) -> Void = { [weak self] seconds in
                Task { @MainActor in
                    guard let self, self.transcribingPath != nil else { return }
                    self.status = "Transcribing with \(name), \(min(Int(seconds), duration)) / \(duration) seconds"
                }
            }
            let work = Task.detached(priority: .userInitiated) { try await transcriber.transcribe(audio, progress: report) }
            analysisCancel = { work.cancel(); audio.cancel() }
            defer { analysisCancel = nil }
            transcriptSegments = try await work.value
            transcript = SpeakerLabels.text(transcriptSegments)
            if transcriptSegments.isEmpty { appendTranscriptionWarning("\(name) heard no speech in this recording.") }
        } catch {
            guard !transcriptionCancelled else {
                appendTranscriptionWarning("Transcription stopped. Complete audio was kept.")
                return
            }
            appendTranscriptionWarning("OpenAI: \(error.localizedDescription) Transcribed with Apple on this Mac instead.")
            await transcribeOnDevice(url, locales: request.locales)
        }
    }

    /// Whisper on this Mac, five minutes of audio at a time.
    private func transcribeWithWhisper(_ url: URL, request: TranscriptionRequest) async {
        let name = "Whisper \(WhisperModel.named(request.whisperModel))"
        guard speechModels.isReady(request.whisperModel) else {
            appendTranscriptionWarning("\(name) is not downloaded. Transcribed with Apple on this Mac instead; download the model in Audio settings.")
            await transcribeOnDevice(url, locales: request.locales)
            return
        }
        status = "Loading \(name)"
        do {
            let kit = try await speechModels.whisperKit(request.whisperModel)
            let audio = try await RecordingPCM(url: url, cipher: store.cipher, sampleRate: 16_000)
            let duration = Int(audio.duration)
            let language = request.languageHint
            let stop = StopFlag()
            status = "Transcribing with \(name), 0 / \(duration) seconds"
            // Decoding and decoding results stay off the main thread; only progress comes back to it.
            let work = Task.detached(priority: .userInitiated) { () -> [TranscriptSegment] in
                var segments: [TranscriptSegment] = []
                let options = DecodingOptions(language: language, temperatureFallbackCount: 3, usePrefillPrompt: language != nil,
                                              detectLanguage: language == nil, skipSpecialTokens: true, chunkingStrategy: .vad)
                try await audio.pieces(of: 300) { offset, samples in
                    let results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in stop.isSet ? false : nil })
                    try Task.checkCancellation()
                    for result in results {
                        for piece in result.segments {
                            let text = WhisperText.clean(piece.text)
                            guard !text.isEmpty else { continue }
                            segments.append(TranscriptSegment(start: offset + Double(piece.start), end: offset + Double(max(piece.end, piece.start + 0.1)),
                                                              text: text, locale: result.language.isEmpty ? nil : result.language))
                        }
                    }
                    let reached = min(duration, Int(offset) + samples.count / 16_000)
                    let sofar = segments
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.transcriptSegments = sofar
                        self.transcript = SpeakerLabels.text(sofar)
                        self.status = "Transcribing with \(name), \(reached) / \(duration) seconds"
                    }
                }
                return segments
            }
            analysisCancel = { stop.set(); work.cancel(); audio.cancel() }
            defer { analysisCancel = nil }
            transcriptSegments = try await work.value
            transcript = SpeakerLabels.text(transcriptSegments)
            if transcriptSegments.isEmpty { appendTranscriptionWarning("\(name) heard no speech in this recording.") }
        } catch {
            guard !transcriptionCancelled else {
                appendTranscriptionWarning("Transcription stopped. Available text and complete audio were kept.")
                return
            }
            appendTranscriptionWarning("\(name): \(error.localizedDescription) Transcribed with Apple on this Mac instead.")
            await transcribeOnDevice(url, locales: request.locales)
        }
    }

    /// Finds who spoke when, on this Mac, and names each voice in the transcript. One voice gets no label.
    private func labelSpeakers(_ url: URL) async {
        guard speechModels.speakers == .ready else {
            appendTranscriptionWarning("Speakers were not labeled: the speaker model is not downloaded. Download it in Audio settings.")
            return
        }
        status = "Finding speakers on this Mac"
        do {
            let audio = try await RecordingPCM(url: url, cipher: store.cipher, sampleRate: 16_000)
            guard audio.duration <= SpeakerLabelLimit.seconds else {
                appendTranscriptionWarning("Speakers are labeled in recordings up to two hours long.")
                return
            }
            let kit = try await speechModels.speakerModel()
            let report: @Sendable (Progress) -> Void = { [weak self] progress in
                let percent = Int(progress.fractionCompleted * 100)
                Task { @MainActor in self?.status = "Finding speakers on this Mac, \(percent)%" }
            }
            let work = Task.detached(priority: .userInitiated) { () -> [SpeakerTurn] in
                let samples = try audio.read(Int(audio.duration * 16_000) + 16_000)
                try Task.checkCancellation()
                let result = try await kit.diarize(audioArray: samples, progressCallback: report)
                return result.segments.compactMap { segment in
                    segment.speaker.speakerId.map { SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: $0) }
                }
            }
            analysisCancel = { work.cancel(); audio.cancel() }
            defer { analysisCancel = nil }
            let turns = try await work.value
            guard Set(turns.map(\.speaker)).count > 1 else { return }
            transcriptSegments = SpeakerLabels.assign(turns, to: transcriptSegments)
        } catch {
            if !transcriptionCancelled { appendTranscriptionWarning("Speakers were not labeled: \(error.localizedDescription)") }
        }
    }

    func cancelTranscription() {
        transcriptionCancelled = true
        if let cancel = analysisCancel { analysisCancel = nil; Task { await cancel() } }
        if speechContinuation != nil {
            appendTranscriptionWarning("Transcription stopped. Available text and complete audio were kept.")
            finishTranscription()
        }
    }

    private func appendWarning(_ message: String) {
        lastError = [lastError, message].compactMap { $0 }.joined(separator: " ")
    }

    private func appendTranscriptionWarning(_ message: String) {
        transcriptionWarnings.append(message)
        appendWarning(message)
    }

    /// macOS 26 and later: every chosen language hears the whole recording in one SpeechAnalyzer pass.
    @available(macOS 26, *)
    private func analyze(_ url: URL, locales: [Locale]) async {
        status = "Transcribing on device"
        analysisReached = [:]
        do {
            let transcribers = locales.map { SpeechLanguages.transcriber($0) }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers) else {
                throw CaptureFailure("The speech models accept no audio format available on this Mac.")
            }
            let audio = try await RecordingAudio(url: url, cipher: store.cipher, format: format)
            let duration = audio.duration
            let analyzer = SpeechAnalyzer(modules: transcribers)
            analysisCancel = { audio.cancel(); await analyzer.cancelAndFinishNow() }
            defer { analysisCancel = nil }
            let heard = try await withThrowingTaskGroup(of: (String, [RecognizedSpeech], String?).self) { group in
                for (locale, transcriber) in zip(locales, transcribers) {
                    let id = locale.identifier(.bcp47)
                    group.addTask {
                        var speech: [RecognizedSpeech] = []
                        do {
                            for try await result in transcriber.results {
                                speech += Self.pieces(result.text, after: !speech.isEmpty, locale: id)
                                await self.reportAnalysis(id, reached: result.range.end.seconds, of: duration, languages: locales.count)
                            }
                            return (id, speech, nil)
                        } catch { return (id, speech, error.localizedDescription) }
                    }
                }
                do {
                    if let end = try await analyzer.analyzeSequence(audio) { try await analyzer.finalizeAndFinish(through: end) }
                    else { await analyzer.cancelAndFinishNow() }
                } catch { await analyzer.cancelAndFinishNow(); throw error }
                var heard: [(String, [RecognizedSpeech], String?)] = []
                for try await item in group { heard.append(item) }
                return heard
            }
            if transcriptionCancelled {
                appendTranscriptionWarning("Transcription stopped before the end of the meeting. Available text and complete audio were kept.")
            } else {
                for (id, _, failure) in heard { if let failure { appendTranscriptionWarning("\(languages.name(for: id)): \(failure)") } }
            }
            transcriptSegments = TranscriptMerge.segments(heard.map { (locale: $0.0, speech: $0.1) }, joinRows: !phraseRows)
            transcript = transcriptSegments.map(\.text).joined(separator: "\n")
        } catch { appendTranscriptionWarning("On-device transcription: \(error.localizedDescription)") }
    }

    private func reportAnalysis(_ id: String, reached: Double, of duration: Double, languages count: Int) {
        guard reached.isFinite else { return }
        analysisReached[id] = max(analysisReached[id] ?? 0, reached)
        let done = analysisReached.count < count ? 0 : analysisReached.values.min() ?? 0
        status = "Transcribing on device, \(Int(min(done, duration))) / \(Int(duration)) seconds"
    }

    @available(macOS 26, *)
    nonisolated private static func pieces(_ text: AttributedString, after earlier: Bool, locale: String) -> [RecognizedSpeech] {
        var pieces: [RecognizedSpeech] = []
        let joiner = TranscriptMerge.joiner(for: locale)
        if earlier, !joiner.isEmpty, text.characters.first?.isWhitespace == false { pieces.append(RecognizedSpeech(text: joiner)) }
        for run in text.runs {
            let range = run.audioTimeRange
            pieces.append(RecognizedSpeech(text: String(text[run.range].characters), start: range?.start.seconds,
                                           end: range?.end.seconds, confidence: run.transcriptionConfidence))
        }
        return pieces
    }

    /// Before macOS 26: each chosen language transcribes 50-second chunks with on-device recognition.
    private func transcribeChunks(_ url: URL, locales: [Locale]) async {
        let recognizers = locales.compactMap { locale -> (String, SFSpeechRecognizer)? in
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return nil }
            return (locale.identifier(.bcp47), recognizer)
        }
        guard !recognizers.isEmpty else {
            appendTranscriptionWarning("On-device speech recognition is unavailable for the chosen languages. Check Audio settings.")
            return
        }
        let directory = url.deletingLastPathComponent().appendingPathComponent(".transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Older systems export chunks from a file; a sealed recording is opened in this
            // private work folder for the duration and removed with it.
            var source = url
            if VaultCipher.isSealed(fileAt: url) {
                source = directory.appendingPathComponent("source.\(url.pathExtension)")
                try store.cipher.contents(of: url).write(to: source)
            }
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 4 * 60 * 60 + 30 else {
                throw CaptureFailure("The audio duration is invalid or exceeds the meeting limit.")
            }
            var offset = 0.0
            var heard: [String: [RecognizedSpeech]] = [:]
            while offset < duration {
                guard !transcriptionCancelled, !Task.isCancelled else {
                    appendTranscriptionWarning("Transcription stopped before the end of the meeting. Complete audio was kept.")
                    break
                }
                let chunkURL = directory.appendingPathComponent("chunk.m4a")
                let end = min(duration, offset + 50)
                do {
                    try await SystemAudioMedia.chunk(asset: asset,
                        range: CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 48000), duration: CMTime(seconds: end - offset, preferredTimescale: 48000)),
                        destination: chunkURL)
                    for (id, recognizer) in recognizers where !transcriptionCancelled {
                        let language = recognizers.count > 1 ? " (\(languages.name(for: id)))" : ""
                        status = "Transcribing on device\(language), \(Int(offset)) / \(Int(duration)) seconds"
                        let chunk = await transcribe(chunkURL, recognizer: recognizer)
                        guard !chunk.pieces.isEmpty else { continue }
                        var pieces = heard[id] ?? []
                        if !pieces.isEmpty { pieces.append(RecognizedSpeech(text: TranscriptMerge.joiner(for: id))) }
                        let span = end - offset
                        pieces += chunk.pieces.map { piece in
                            var shifted = piece
                            shifted.start = piece.start.map { offset + min(max(0, $0), span) }
                            shifted.end = piece.end.map { offset + min(max(0, $0), span) }
                            return shifted
                        }
                        heard[id] = pieces
                    }
                    transcriptSegments = TranscriptMerge.segments(heard.map { (locale: $0.key, speech: $0.value) }, joinRows: !phraseRows)
                    transcript = transcriptSegments.map(\.text).joined(separator: "\n")
                } catch { appendTranscriptionWarning("Transcript gap at \(Int(offset)) seconds: \(error.localizedDescription)") }
                try? FileManager.default.removeItem(at: chunkURL)
                offset = end
            }
        } catch { appendTranscriptionWarning("On-device transcription: \(error.localizedDescription)") }
    }

    private func transcribe(_ url: URL, recognizer: SFSpeechRecognizer) async -> SpeechChunk {
        await withCheckedContinuation { continuation in
            speechChunk = SpeechChunk()
            speechGeneration = UUID()
            let token = speechGeneration
            speechContinuation = continuation
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let pieces = result.map { Self.pieces($0.bestTranscription) }
                let finished = result?.isFinal == true || error != nil
                Task { @MainActor in
                    guard let self, self.speechGeneration == token, self.speechContinuation != nil else { return }
                    if let pieces { self.speechChunk = SpeechChunk(pieces: pieces) }
                    if finished {
                        if let error { self.appendTranscriptionWarning("On-device transcription: \(error.localizedDescription)") }
                        self.finishTranscription()
                    }
                }
            }
            speechTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.speechGeneration == token, self.speechContinuation != nil else { return }
                self.appendTranscriptionWarning("An on-device transcript chunk timed out. Available text and audio were kept.")
                self.finishTranscription()
            }
        }
    }

    /// Words with their timing, plus the spacing and punctuation between them in the formatted text.
    nonisolated private static func pieces(_ transcription: SFTranscription) -> [RecognizedSpeech] {
        let text = transcription.formattedString as NSString
        var pieces: [RecognizedSpeech] = []
        var cursor = 0
        for segment in transcription.segments {
            let range = segment.substringRange
            guard range.location != NSNotFound, range.location >= cursor, NSMaxRange(range) <= text.length else { continue }
            if range.location > cursor { pieces.append(RecognizedSpeech(text: text.substring(with: NSRange(location: cursor, length: range.location - cursor)))) }
            let timed = segment.timestamp.isFinite && segment.duration.isFinite && segment.duration >= 0
            pieces.append(RecognizedSpeech(text: text.substring(with: range), start: timed ? segment.timestamp : nil,
                                           end: timed ? segment.timestamp + segment.duration : nil,
                                           confidence: segment.confidence > 0 ? Double(segment.confidence) : nil))
            cursor = NSMaxRange(range)
        }
        if cursor < text.length { pieces.append(RecognizedSpeech(text: text.substring(from: cursor))) }
        return pieces
    }

    private func finishTranscription() {
        let continuation = speechContinuation
        speechContinuation = nil
        speechTimeout?.cancel()
        speechTimeout = nil
        speechTask?.cancel()
        speechTask = nil
        speechGeneration = UUID()
        continuation?.resume(returning: speechChunk)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording, self.recorder === recorder else { return }
            if !flag { self.lastError = "Microphone recording ended unexpectedly." }
            await self.stop()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.appendWarning(error?.localizedDescription ?? "Microphone encoding failed.")
            await self.stop()
        }
    }
}

/// A library recording decoded for the speech analyzer straight from its sealed file, at the
/// analyzer's pace and without a plaintext copy.
@available(macOS 26, *)
private final class RecordingAudio: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput
    let duration: Double
    private let media: VaultAsset
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let format: AVAudioFormat

    init(url: URL, cipher: VaultCipher, format: AVAudioFormat) async throws {
        media = try VaultAsset(url: url, cipher: cipher)
        guard let track = try await media.asset.loadTracks(withMediaType: .audio).first else { throw CaptureFailure("The recording has no audio track.") }
        duration = try await media.asset.load(.duration).seconds
        reader = try AVAssetReader(asset: media.asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: format.settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CaptureFailure("The recording cannot be decoded for transcription.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CaptureFailure("The recording cannot be decoded for transcription.") }
        self.format = format
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let source: RecordingAudio
        func next() async throws -> AnalyzerInput? { try source.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: self) }

    func cancel() { reader.cancelReading() }

    private func next() throws -> AnalyzerInput? {
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
                throw CaptureFailure("The recording could not be decoded for transcription.")
            }
            return AnalyzerInput(buffer: buffer, bufferStartTime: CMSampleBufferGetPresentationTimeStamp(sample))
        }
        if reader.status == .failed { throw reader.error ?? CaptureFailure("The recording could not be decoded for transcription.") }
        return nil
    }
}
