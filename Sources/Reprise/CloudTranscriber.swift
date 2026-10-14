import Foundation
import RepriseCore

/// Transcribes a saved recording with OpenAI's transcription models through a ChatGPT sign-in.
/// The recording goes out in ten-minute pieces, a few sessions at a time, and OpenAI's voice
/// detection times every utterance. The audio is sent as fast as the connection takes it.
struct CloudTranscriber {
    let credential: OpenAICredential
    let model: String
    /// A language hint such as "ko"; nil lets the model recognize the language.
    let language: String?
    static let pieceSeconds = 600.0
    static let parallelSessions = 3

    func transcribe(_ audio: RecordingPCM, progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        let done = ProgressTally()
        var segments: [TranscriptSegment] = []
        try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
            var running = 0
            try await audio.pieces(of: Self.pieceSeconds) { offset, samples in
                if running == Self.parallelSessions, let finished = try await group.next() { segments += finished; running -= 1 }
                let pcm = OpenAIRealtime.pcm16(samples[...])
                let seconds = Double(samples.count) / audio.sampleRate
                group.addTask { [self] in
                    let result = try await piece(pcm, offset: offset)
                    progress(await done.add(seconds))
                    return result
                }
                running += 1
            }
            for try await finished in group { segments += finished }
        }
        return segments.sorted { $0.start < $1.start }
    }

    /// One piece in its own session, tried twice when the connection drops.
    private func piece(_ pcm: Data, offset: Double) async throws -> [TranscriptSegment] {
        do { return try await session(pcm, offset: offset) }
        catch let failure as OpenAIRealtime.Failure where failure.code == nil || failure.code == "connection" {
            try await Task.sleep(for: .seconds(2))
            return try await session(pcm, offset: offset)
        }
    }

    private func session(_ pcm: Data, offset: Double) async throws -> [TranscriptSegment] {
        let secret = try await OpenAIRealtime.clientSecret(credential, session: OpenAIRealtime.transcriptionSession(model: model, language: language, vad: true))
        let socket = OpenAIRealtime.connect(secret: secret)
        defer { socket.close() }
        var items = UtteranceLog()
        let sent = StopFlag()
        var sender: Task<Void, Error>?
        defer { sender?.cancel() }
        let watchdog = Watchdog(seconds: 90) { socket.close() }
        defer { watchdog.stop() }
        for try await event in socket.events {
            watchdog.reset()
            let type = event["type"] as? String ?? ""
            switch type {
            case "session.created":
                sender = Task {
                    // One second per message; two seconds of silence let voice detection close the last utterance.
                    let step = 48_000
                    var position = 0
                    while position < pcm.count {
                        try Task.checkCancellation()
                        try await socket.send(["type": "input_audio_buffer.append", "audio": pcm[position..<min(pcm.count, position + step)].base64EncodedString()])
                        position += step
                    }
                    try await socket.send(["type": "input_audio_buffer.append", "audio": Data(count: 96_000).base64EncodedString()])
                    try await socket.send(["type": "input_audio_buffer.commit"])
                    sent.set()
                }
            case "input_audio_buffer.speech_started":
                if let id = event["item_id"] as? String { items.started(id, at: (event["audio_start_ms"] as? Double).map { $0 / 1000 }) }
            case "input_audio_buffer.speech_stopped":
                if let id = event["item_id"] as? String { items.stopped(id, at: (event["audio_end_ms"] as? Double).map { $0 / 1000 }) }
            case "input_audio_buffer.committed":
                if let id = event["item_id"] as? String { items.committed(id, afterClosingCommit: sent.isSet) }
            case "conversation.item.input_audio_transcription.completed":
                if let id = event["item_id"] as? String { items.finished(id, text: event["transcript"] as? String ?? "") }
            case "conversation.item.input_audio_transcription.failed":
                if let id = event["item_id"] as? String { items.finished(id, text: "") }
            case "error":
                let error = event["error"] as? [String: Any] ?? [:]
                let code = error["code"] as? String
                // The closing commit finds the buffer empty once voice detection has taken every utterance.
                if code == "input_audio_buffer_commit_empty" { items.commitResolved = true }
                else { throw OpenAIRealtime.Failure("OpenAI transcription: \(error["message"] as? String ?? "an error occurred").", code: code ?? "error") }
            default: break
            }
            if let sender, sent.isSet, items.isComplete {
                try await sender.value
                return items.segments(offset: offset, end: Double(pcm.count) / 48_000)
            }
        }
        if watchdog.fired { throw OpenAIRealtime.Failure("OpenAI stopped answering during transcription.", code: "connection") }
        throw OpenAIRealtime.Failure("The connection to OpenAI closed during transcription.", code: "connection")
    }
}

/// Utterances of one session, from voice detection to finished text.
private struct UtteranceLog {
    struct Utterance { var start: Double?; var end: Double?; var text: String?; var committed = false }
    private var order: [String] = []
    private var items: [String: Utterance] = [:]
    var commitResolved = false

    mutating func started(_ id: String, at time: Double?) { touch(id); items[id]?.start = time }
    mutating func stopped(_ id: String, at time: Double?) { touch(id); items[id]?.end = time }
    mutating func committed(_ id: String, afterClosingCommit: Bool) {
        touch(id)
        // A commit of speech voice detection never closed is the answer to the closing commit.
        if afterClosingCommit, items[id]?.end == nil { commitResolved = true }
        items[id]?.committed = true
    }
    mutating func finished(_ id: String, text: String) { touch(id); items[id]?.text = text }
    private mutating func touch(_ id: String) { if items[id] == nil { items[id] = Utterance(); order.append(id) } }

    /// Every utterance is known and transcribed once the closing commit is answered.
    var isComplete: Bool { commitResolved && items.values.allSatisfy { !$0.committed || $0.text != nil } }

    func segments(offset: Double, end: Double) -> [TranscriptSegment] {
        var previousEnd = 0.0
        return order.compactMap { id in
            guard let item = items[id], let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let start = min(item.start ?? previousEnd, end)
            let stop = max(start + 0.1, min(item.end ?? end, end))
            previousEnd = stop
            return TranscriptSegment(start: offset + start, end: offset + stop, text: text)
        }
    }
}

private actor ProgressTally {
    private var seconds = 0.0
    func add(_ value: Double) -> Double { seconds += value; return seconds }
}

/// Calls `action` when `reset` has not been called for `seconds`.
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date
    private var task: Task<Void, Never>?
    private(set) var fired = false
    private let seconds: Double

    init(seconds: Double, action: @escaping @Sendable () -> Void) {
        self.seconds = seconds
        deadline = Date().addingTimeInterval(seconds)
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let expired = self.lock.withLock { () -> Bool in
                    guard Date() >= self.deadline, !self.fired else { return false }
                    self.fired = true
                    return true
                }
                if expired { action(); return }
            }
        }
    }

    func reset() { lock.withLock { deadline = Date().addingTimeInterval(seconds) } }
    func stop() { task?.cancel() }
}
