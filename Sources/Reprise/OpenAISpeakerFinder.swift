import Foundation
import RepriseCore

/// Finds who spoke when with OpenAI's diarization model, in 20-minute pieces of compressed
/// audio. The first piece goes alone; the others then go a few at a time with a clip of each
/// voice it heard, so a voice keeps its number through the whole recording.
struct OpenAISpeakerFinder {
    let credential: OpenAICredential
    /// A language hint such as "ko"; nil lets the model recognize the language.
    let language: String?
    /// OpenAI splits audio at pauses itself; pieces this long stay well under its 25 MB upload limit.
    var pieceSeconds = 1_200.0
    static let sampleRate = 16_000.0

    /// `progress` gets the pieces finished and the total.
    func turns(_ audio: RecordingPCM, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [SpeakerTurn] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-speakers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let total = audio.duration <= pieceSeconds + 20 ? 1 : Int((audio.duration / pieceSeconds).rounded(.up))
        progress(0, total)
        var voices = VoiceNumbers()
        var references: [OpenAIDiarization.Reference] = []
        var turns: [SpeakerTurn] = [], index = 0, done = 0
        try await withThrowingTaskGroup(of: (offset: Double, piece: Int, turns: [OpenAIDiarization.Turn]).self) { group in
            var running = 0
            func take(_ finished: (offset: Double, piece: Int, turns: [OpenAIDiarization.Turn])) {
                turns += finished.turns.map { SpeakerTurn(start: finished.offset + $0.start, end: finished.offset + $0.end,
                                                          speaker: voices.number($0.speaker, piece: finished.piece)) }
                done += 1
                progress(done, total)
            }
            try await audio.pieces(of: pieceSeconds) { offset, samples in
                index += 1
                let piece = index
                let file = folder.appendingPathComponent("piece-\(piece).m4a")
                try RecordingPCM.writeAAC(samples, sampleRate: audio.sampleRate, to: file)
                let seconds = Double(samples.count) / audio.sampleRate
                if piece == 1 {
                    let found = try await diarize(file, duration: seconds, references: [])
                    // Voices are named in the order they first speak; the clips carry those names on.
                    for voice in found.sorted(by: { $0.start < $1.start }) { _ = voices.number(voice.speaker, piece: 1) }
                    references = OpenAIDiarization.referenceSpans(found).map { span in
                        let lower = max(0, Int(span.start * audio.sampleRate)), upper = min(samples.count, Int(span.end * audio.sampleRate))
                        return OpenAIDiarization.Reference(name: voices.name(span.speaker, piece: 1),
                                                           wav: OpenAIDiarization.wav(samples[lower..<max(lower, upper)], sampleRate: Int(audio.sampleRate)))
                    }
                    take((offset, piece, found))
                    return
                }
                if running == 3, let finished = try await group.next() { take(finished); running -= 1 }
                let known = references
                group.addTask { [self] in (offset, piece, try await diarize(file, duration: seconds, references: known)) }
                running += 1
            }
            for try await finished in group { take(finished) }
        }
        return turns
    }

    /// One piece, read and deleted before it is sent; tried twice when the connection drops.
    private func diarize(_ file: URL, duration: Double, references: [OpenAIDiarization.Reference]) async throws -> [OpenAIDiarization.Turn] {
        let audio = try Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
        let timeout = max(300, duration * 0.75)
        func once() async throws -> [OpenAIDiarization.Turn] {
            try await OpenAIDiarization.turns(audio, filename: "recording.m4a", mimeType: "audio/mp4", credential: credential,
                                              language: language, references: references, timeout: timeout)
        }
        do { return try await once() }
        catch let error as URLError where [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost].contains(error.code) {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            return try await once()
        }
    }
}

/// Numbers for the voices OpenAI returns: the names given to voices of the first piece hold
/// everywhere, and any other voice gets a new number of its own piece.
struct VoiceNumbers {
    private var numbers: [String: Int] = [:]
    private var names: [Int: String] = [:]

    mutating func number(_ label: String, piece: Int) -> Int {
        // Names Reprise gave come back as given; OpenAI's own letters belong to one piece.
        if piece > 1, let known = names.first(where: { $0.value == label })?.key { return known }
        let key = "\(piece):\(label)"
        if let number = numbers[key] { return number }
        let number = numbers.count + 1
        numbers[key] = number
        if piece == 1 { names[number] = SpeakerLabels.defaultName(number) }
        return number
    }

    /// The name a voice of the first piece is passed on with.
    func name(_ label: String, piece: Int) -> String {
        numbers["\(piece):\(label)"].flatMap { names[$0] } ?? label
    }
}
