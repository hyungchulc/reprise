@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// Where live audio comes from: everything the Mac plays, or the microphone.
enum LiveAudioInput: String, Codable, CaseIterable, Identifiable {
    case system, microphone
    var id: String { rawValue }
    var title: String { self == .system ? "Mac audio" : "Microphone" }
}

/// Live audio that captions listen to; tests play a recording instead.
protocol LiveAudioFeed: AnyObject {
    func start() async throws
    func stop()
}

/// Live audio as mono float buffers at one sample rate, delivered on a private queue as it plays.
/// Mac audio comes through ScreenCaptureKit without Reprise's own sounds; the microphone through
/// the audio engine.
final class LiveAudioSource: NSObject, SCStreamOutput, SCStreamDelegate, LiveAudioFeed, @unchecked Sendable {
    let format: AVAudioFormat
    private let input: LiveAudioInput
    private let deliver: (AVAudioPCMBuffer) -> Void
    private let failed: (String) -> Void
    private let queue = DispatchQueue(label: "Reprise.live-audio")
    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    init(_ input: LiveAudioInput, sampleRate: Double, deliver: @escaping (AVAudioPCMBuffer) -> Void, failed: @escaping (String) -> Void) {
        self.input = input
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        self.deliver = deliver
        self.failed = failed
    }

    func start() async throws {
        switch input {
        case .system: try await startSystem()
        case .microphone: try startMicrophone()
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func startSystem() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw SystemAudioFailure("Allow Screen Recording for Reprise to caption Mac audio.")
        }
        // ScreenCaptureKit can stall while finding or starting a stream; captions then say so instead of waiting.
        let content = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCShareableContent, Error>) in
            let completion = AudioThrowingCompletion(continuation)
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let content { completion.finish(.success(content)) }
                else { completion.finish(.failure(error ?? SystemAudioFailure("Mac audio could not be found."))) }
            }
            completion.timeout(after: 15, message: "Mac audio did not start in time. Turn captions off and on again.")
        }
        guard let display = content.displays.first else { throw SystemAudioFailure("No display is available for Mac audio.") }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = capture
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = AudioCompletion(continuation)
            capture.startCapture { error in
                // A start that succeeds after its timeout must not leave audio running.
                if !completion.finish(error.map { .failure($0) } ?? .success(())), error == nil { capture.stopCapture(completionHandler: nil) }
            }
            completion.timeout(after: 15, message: "Mac audio did not start in time. Turn captions off and on again.")
        }
    }

    private func startMicrophone() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw SystemAudioFailure("Allow microphone access for Reprise to caption the microphone.")
        }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let hardware = node.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw SystemAudioFailure("No microphone is available.") }
        node.installTap(onBus: 0, bufferSize: 4_096, format: hardware) { [weak self] buffer, _ in
            self?.queue.async { self?.convert(buffer) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { failed(error.localizedDescription) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        var basic = stream.pointee
        guard let format = AVAudioFormat(streamDescription: &basic) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        convert(buffer)
    }

    /// Mixes down and resamples to the requested format. Runs on the private queue.
    private func convert(_ buffer: AVAudioPCMBuffer) {
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInput = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { deliver(output) }
    }
}
