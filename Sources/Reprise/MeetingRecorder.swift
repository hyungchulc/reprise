import AppKit
import AVFoundation
import Combine
import Speech
import CoreGraphics
import RepriseCore

@MainActor
final class MeetingRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Not recording"
    @Published private(set) var lastError: String?
    @Published private(set) var transcript = ""
    @Published private(set) var systemAudioAvailable = false
    @Published private(set) var isBusy = false
    @Published private(set) var transcribingMomentID: String?
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
        var text = ""
        var start: Double?
        var end: Double?
    }
    private var speechContinuation: CheckedContinuation<SpeechChunk, Never>?
    private var speechGeneration = UUID()
    private var speechChunk = SpeechChunk()
    private var transcriptSegments: [TranscriptSegment] = []
    private var transcriptionWarnings: [String] = []
    private var transcriptionCancelled = false
    private var transcriptionEnabled = true
    private var transcriptionLocale = Locale.current.identifier
    private var observers: [NSObjectProtocol] = []

    init(store: MomentStore, root: URL) {
        self.store = store
        self.root = root
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

    func start(title: String = "Meeting", includeSystemAudio: Bool = true, transcribe: Bool = true, speechLocale: String = Locale.current.identifier) async {
        guard !isRecording, !starting, !finalizing else { return }
        transcriptionEnabled = transcribe
        transcriptionLocale = speechLocale
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
                        appendWarning("Saved microphone only. Mixing failed: \(error.localizedDescription). System audio retained at \(systemAudio.lastPathComponent).")
                    }
                } else if let systemFile {
                    try? FileManager.default.removeItem(at: systemFile)
                    appendWarning("Saved microphone only.")
                }
            }
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else { throw CaptureFailure("The microphone recording is empty.") }
            let savedAsset = AVURLAsset(url: url)
            let savedDuration = try await savedAsset.load(.duration).seconds
            guard savedDuration.isFinite, savedDuration > 0,
                  !(try await savedAsset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw CaptureFailure("The meeting audio is not playable.")
            }
            // Index the complete audio before transcription, so interruption cannot hide it.
            let moment = Moment(timestamp: timestamp, appName: "Meeting", windowTitle: title,
                                videoPath: savedPath, kind: "meeting", byteCount: bytes, audioDuration: savedDuration,
                                transcriptionNote: transcriptionEnabled ? "Transcription has not completed." : "Automatic transcription is off.")
            try await store.insert(moment)
            lastSavedMoment = moment
            if transcriptionEnabled { await transcribeStoredAudio(moment, url: url, locale: transcriptionLocale) }
            status = lastError != nil ? "Meeting saved with warnings" : (transcript.isEmpty ? "Meeting saved, no transcript available" : "Meeting saved")
        } catch {
            // Keep the original audio recoverable when indexing fails.
            appendWarning("\(error.localizedDescription) Audio retained at \(savedPath).")
            status = "Meeting could not be indexed"
        }
    }

    func transcribeSaved(_ moment: Moment, locale: String) async {
        guard !isRecording, !isBusy, !starting, !finalizing, moment.kind == "meeting", let path = moment.videoPath else { return }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.isReadableFile(atPath: url.path) else {
            lastError = "The original audio file is unavailable."; return
        }
        isBusy = true; finalizing = true; lastError = nil; transcriptionCancelled = false
        defer { isBusy = false; finalizing = false }
        await transcribeStoredAudio(moment, url: url, locale: locale)
        status = lastError == nil ? "Transcript saved" : "Transcription needs attention"
    }

    private func transcribeStoredAudio(_ moment: Moment, url: URL, locale: String) async {
        transcribingMomentID = moment.id
        defer { transcribingMomentID = nil }
        transcript = ""; transcriptSegments = []; transcriptionWarnings = []
        if transcriptionCancelled {
            appendTranscriptionWarning("Transcription was interrupted. Complete audio was kept.")
        } else if SFSpeechRecognizer.authorizationStatus() != .authorized {
            appendTranscriptionWarning("Speech Recognition permission is not allowed. Enable it in Privacy settings to transcribe this recording.")
        } else if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
            status = "Transcribing on device"
            await transcribeChunks(url, recognizer: recognizer)
            if transcript.isEmpty, transcriptionWarnings.isEmpty {
                appendTranscriptionWarning("No speech was recognized in the selected language (\(locale)).")
            }
        } else {
            appendTranscriptionWarning("On-device speech recognition is unavailable for \(locale). Choose a supported transcription language in Audio settings.")
        }
        do {
            let note = transcriptionWarnings.isEmpty ? nil : transcriptionWarnings.joined(separator: " ")
            try await store.updateTranscript(id: moment.id, text: transcript.isEmpty ? moment.text : transcript,
                segments: transcript.isEmpty ? (moment.transcriptSegments ?? []) : transcriptSegments, note: note)
            lastSavedMoment = try await store.moment(id: moment.id)
        } catch { appendWarning("Could not save transcript: \(error.localizedDescription)") }
    }

    func cancelTranscription() {
        transcriptionCancelled = true
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

    private func transcribeChunks(_ url: URL, recognizer: SFSpeechRecognizer) async {
        let directory = url.deletingLastPathComponent().appendingPathComponent(".transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 4 * 60 * 60 + 30 else {
                throw CaptureFailure("The audio duration is invalid or exceeds the meeting limit.")
            }
            var offset = 0.0
            var parts: [String] = []
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
                    if transcriptionCancelled { try? FileManager.default.removeItem(at: chunkURL); continue }
                    status = "Transcribing on device, \(Int(offset)) / \(Int(duration)) seconds"
                    let chunk = await transcribe(chunkURL, recognizer: recognizer)
                    if !chunk.text.isEmpty {
                        parts.append(chunk.text)
                        let start = offset + max(0, min(chunk.start ?? 0, end - offset - 0.001))
                        let finish = min(end, max(start + 0.001, offset + (chunk.end ?? (end - offset))))
                        transcriptSegments.append(TranscriptSegment(start: start, end: finish, text: chunk.text))
                    }
                    transcript = parts.joined(separator: "\n")
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
                let text = result?.bestTranscription.formattedString
                let timedWords = result?.bestTranscription.segments.filter { $0.timestamp.isFinite && $0.duration.isFinite && $0.duration > 0 }
                let start = timedWords?.first?.timestamp
                let end = timedWords?.last.map { $0.timestamp + $0.duration }
                let finished = result?.isFinal == true || error != nil
                Task { @MainActor in
                    guard let self, self.speechGeneration == token, self.speechContinuation != nil else { return }
                    if let text { self.speechChunk = SpeechChunk(text: text, start: start, end: end) }
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
