@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

// Capture only audio outputs; no screen frames are persisted or delivered to this writer.
@MainActor
final class SystemAudioRecorder {
    private var stream: SCStream?
    private let output: SystemAudioOutput
    private let queue = DispatchQueue(label: "Reprise.meeting.system-audio")

    init(url: URL, origin: CMTime, onFailure: @escaping (String) -> Void) throws {
        output = try SystemAudioOutput(url: url, origin: origin, onFailure: onFailure)
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw SystemAudioFailure("Screen Recording permission is required for system audio.")
        }
        let content = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCShareableContent, Error>) in
            let completion = AudioThrowingCompletion(continuation)
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let content { completion.finish(.success(content)) }
                else { completion.finish(.failure(error ?? SystemAudioFailure("System audio discovery failed."))) }
            }
            completion.timeout(after: 15, message: "System audio discovery timed out.")
        }
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw SystemAudioFailure("No display is available for system audio.") }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let capture = SCStream(filter: filter, configuration: configuration, delegate: output)
        try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
        stream = capture
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = AudioCompletion(continuation)
            capture.startCapture { error in
                if !completion.finish(error.map { .failure($0) } ?? .success(())), error == nil {
                    // A late successful startup must not revive capture after its timeout teardown.
                    capture.stopCapture(completionHandler: nil)
                }
            }
            completion.timeout(after: 15, message: "System audio startup timed out.")
        }
        if let failure = output.failureMessage { throw SystemAudioFailure(failure) }
    }

    func stop() async -> SystemAudioResult {
        var warning: String?
        if let capture = stream {
            stream = nil
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion = AudioCompletion(continuation)
                    capture.stopCapture { error in completion.finish(error.map { .failure($0) } ?? .success(())) }
                    completion.timeout(after: 10, message: "System audio shutdown timed out.")
                }
            } catch { warning = error.localizedDescription }
            try? capture.removeStreamOutput(output, type: .audio)
        }
        return await output.finish(on: queue, warning: warning)
    }

    deinit {
        stream?.stopCapture(completionHandler: nil)
        let writer = output
        queue.async { writer.cancel() }
    }
}

struct SystemAudioResult {
    let url: URL?
    let offset: Double
    let warning: String?
}

struct SystemAudioFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let origin: CMTime
    private let onFailure: (String) -> Void
    private var firstTimestamp: CMTime?
    private var acceptedSamples = 0
    private var droppedSamples = 0
    private var accepting = true
    private var failure: String?
    private let failureLock = NSLock()

    var failureMessage: String? {
        failureLock.lock(); defer { failureLock.unlock() }
        return failure
    }

    init(url: URL, origin: CMTime, onFailure: @escaping (String) -> Void) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw SystemAudioFailure("Cannot encode system audio.") }
        writer.add(input)
        self.origin = origin
        self.onFailure = onFailure
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { report(error.localizedDescription) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, type == .audio, CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, timestamp.isNumeric else { return }
        guard CMTimeSubtract(timestamp, origin).seconds <= 4 * 60 * 60 else {
            accepting = false
            report("The four-hour recording limit was reached.")
            return
        }
        if firstTimestamp == nil {
            guard writer.startWriting() else { accepting = false; report(writer.error?.localizedDescription ?? "Cannot start the system audio writer."); return }
            writer.startSession(atSourceTime: timestamp)
            firstTimestamp = timestamp
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: writer.outputURL.path)
        }
        guard input.isReadyForMoreMediaData else { droppedSamples += 1; return }
        if input.append(sampleBuffer) { acceptedSamples += 1 }
        else { accepting = false; report(writer.error?.localizedDescription ?? "System audio encoding failed.") }
    }

    private func report(_ message: String) {
        failureLock.lock()
        let first = failure == nil
        if first { failure = message }
        failureLock.unlock()
        if first { onFailure(message) }
    }

    func cancel() { accepting = false; if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() } }

    func finish(on queue: DispatchQueue, warning: String?) async -> SystemAudioResult {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                self.failureLock.lock()
                let failure = self.failure
                self.failureLock.unlock()
                let warnings = [warning, failure, self.droppedSamples > 0 ? "Some system audio samples were dropped while encoding." : nil].compactMap { $0 }
                let message = warnings.isEmpty ? nil : warnings.joined(separator: " ")
                guard self.acceptedSamples > 0, self.writer.status == .writing else {
                    self.cancel()
                    continuation.resume(returning: SystemAudioResult(url: nil, offset: 0,
                        warning: message ?? "No system audio samples were captured."))
                    return
                }
                self.input.markAsFinished()
                let completion = AudioCompletionResult<SystemAudioResult>(continuation)
                self.writer.finishWriting {
                    let success = self.writer.status == .completed
                    completion.finish(SystemAudioResult(url: success ? self.writer.outputURL : nil,
                        offset: max(0, CMTimeSubtract(self.firstTimestamp ?? self.origin, self.origin).seconds),
                        warning: success ? message : (self.writer.error?.localizedDescription ?? "System audio could not be saved.")))
                }
                queue.asyncAfter(deadline: .now() + 15) {
                    if completion.finish(SystemAudioResult(url: nil, offset: 0, warning: "System audio encoding timed out.")) {
                        self.writer.cancelWriting()
                    }
                }
            }
        }
    }
}

// Native callbacks and timeout paths may race. Exactly one path owns each continuation.
private final class AudioCompletionResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    @discardableResult func finish(_ value: Value) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

typealias AudioCompletion = AudioThrowingCompletion<Void>

final class AudioThrowingCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
    func timeout(after seconds: Double, message: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.finish(.failure(SystemAudioFailure(message))) }
    }
}

@MainActor
enum SystemAudioMedia {
    static func mix(microphone: URL, system: URL, systemOffset: Double, destination: URL) async throws {
        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        for (url, offset) in [(microphone, 0.0), (system, systemOffset)] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw SystemAudioFailure("A recorded audio track is missing.")
            }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: CMTime(seconds: offset, preferredTimescale: 48000))
            let gain = AVMutableAudioMixInputParameters(track: track)
            gain.setVolume(0.5, at: .zero)
            parameters.append(gain)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        try await export(asset: composition, destination: destination, mix: mix)
    }

    static func chunk(asset: AVAsset, range: CMTimeRange, destination: URL) async throws {
        try await export(asset: asset, destination: destination, range: range)
    }

    private static func export(asset: AVAsset, destination: URL, range: CMTimeRange? = nil, mix: AVAudioMix? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SystemAudioFailure("Audio export is unavailable.")
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        session.audioMix = mix
        if let range { session.timeRange = range }
        do {
            try await SystemAudioExport(session: session).run()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

// Keep AVAssetExportSession access on one actor while its native encoder runs in the background.
@MainActor
private final class SystemAudioExport {
    private let session: AVAssetExportSession
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false

    init(session: AVAssetExportSession) { self.session = session }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !cancelled else { complete(.failure(CancellationError())); return }
                session.exportAsynchronously { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.complete(self.session.status == .completed ? .success(()) : .failure(self.session.error ?? SystemAudioFailure("Audio export failed.")))
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    self?.cancel(error: SystemAudioFailure("Audio export timed out."))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(error: CancellationError()) }
        }
    }

    private func cancel(error: Error) {
        cancelled = true
        session.cancelExport()
        complete(.failure(error))
    }

    private func complete(_ result: Result<Void, Error>) {
        let pending = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        pending?.resume(with: result)
    }
}
