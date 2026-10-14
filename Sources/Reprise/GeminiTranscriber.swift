import AVFoundation
import Foundation
import RepriseCore

/// Transcribes a saved recording with Gemini, in 20-minute pieces, a few at a time. Each piece
/// goes out as compressed audio from a private temporary file that is deleted as soon as it is
/// sent. Gemini names the voices within a piece, so its speaker labels hold for recordings of
/// one piece.
struct GeminiTranscriber {
    let access: GeminiAccess
    let model: String
    /// Antigravity chosen in AI & Models; nil finds the installed one.
    let executable: String?
    let speakers: Bool
    let language: String?
    /// Through Antigravity, Gemini thinks at length before it writes; 20 minutes of speech keeps
    /// the thinking and the transcript within one answer.
    static let pieceSeconds = 1_200.0
    static let sampleRate = 16_000.0

    struct Result {
        var segments: [TranscriptSegment]
        /// Gemini labeled the voices of the whole recording.
        var labeledSpeakers: Bool
        var model: String
    }

    /// `progress` gets the pieces finished and the total.
    func transcribe(_ audio: RecordingPCM, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-gemini-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        // Pieces are cut at a quiet moment up to 20 seconds either side of each boundary.
        let total = audio.duration <= Self.pieceSeconds + 20 ? 1 : Int((audio.duration / Self.pieceSeconds).rounded(.up))
        let parallel = access == .subscription ? 2 : 3
        let done = PieceTally()
        progress(0, total)
        var segments: [TranscriptSegment] = [], served = model, index = 0
        try await withThrowingTaskGroup(of: (segments: [TranscriptSegment], model: String).self) { group in
            var running = 0
            try await audio.pieces(of: Self.pieceSeconds) { offset, samples in
                if running == parallel, let finished = try await group.next() { segments += finished.segments; served = finished.model; running -= 1 }
                index += 1
                let file = folder.appendingPathComponent("recording-\(index).\(access == .subscription ? "m4a" : "aac")")
                try Self.write(samples, sampleRate: audio.sampleRate, to: file)
                let seconds = Double(samples.count) / audio.sampleRate
                group.addTask { [self] in
                    defer { try? FileManager.default.removeItem(at: file) }
                    let result = try await piece(file, offset: offset, duration: seconds)
                    progress(await done.add(), total)
                    return result
                }
                running += 1
            }
            for try await finished in group { segments += finished.segments; served = finished.model }
        }
        // Voices are named per piece, so only a one-piece recording keeps them. One voice gets no label.
        let voices = Set(segments.compactMap(\.speaker))
        let labeled = speakers && index == 1 && !voices.isEmpty
        if !labeled || voices.count < 2 { segments = segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, locale: $0.locale) } }
        return Result(segments: segments.sorted { $0.start < $1.start }, labeledSpeakers: labeled, model: served)
    }

    /// One piece, tried twice when the connection or the CLI fails on its way.
    private func piece(_ file: URL, offset: Double, duration: Double) async throws -> (segments: [TranscriptSegment], model: String) {
        // 20 minutes of speech took about 6 minutes through Antigravity; this leaves room for a slow day.
        let timeout = max(300, duration * 0.75)
        func once() async throws -> (segments: [TranscriptSegment], model: String) {
            let answer = try await GeminiTranscription.transcribe(file, access: access, model: model, executable: executable,
                                                                  speakers: speakers, language: language, timeout: timeout)
            return (GeminiTranscription.segments(answer.lines, offset: offset, duration: duration, speakers: speakers), answer.model)
        }
        do { return try await once() }
        catch let error as AIProviderError where Self.worthRetrying(error) {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            return try await once()
        }
    }

    /// A broken answer or a CLI that stopped; a timeout or refusal would only repeat.
    static func worthRetrying(_ error: AIProviderError) -> Bool {
        switch error {
        case .invalidResponse, .providerFailed, .processFailed: true
        default: false
        }
    }

    /// Mono AAC at 32 kbps: an `.m4a` file, or raw AAC for an `.aac` name. Gemini hears audio at
    /// 16 kbps, so this loses nothing it would use.
    static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = Int(sampleRate) * 10
        var position = 0
        while position < samples.count {
            let count = min(step, samples.count - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { throw CaptureFailure("The recording could not be prepared for Gemini.") }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + position, count: count) }
            try file.write(from: buffer)
            position += count
        }
    }
}

/// Pieces done and in all, for the status line.
final class PartsDone: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0, total = 0
    var value: (done: Int, total: Int) { lock.withLock { (done, total) } }
    func set(_ done: Int, _ total: Int) { lock.withLock { self.done = done; self.total = total } }
}

private actor PieceTally {
    private var count = 0
    func add() -> Int { count += 1; return count }
}
