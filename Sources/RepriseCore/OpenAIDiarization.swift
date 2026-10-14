import Foundation

/// Who spoke when, from OpenAI's diarization model, through the same ChatGPT sign-in or API key
/// as transcription. Only the speakers' turns are used; the transcript's words come from the
/// chosen engine. Voices heard in an earlier piece are passed on as short clips, so a voice keeps
/// its name across a long recording.
public enum OpenAIDiarization {
    public static let model = "gpt-4o-transcribe-diarize"

    public struct Turn: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let speaker: String
        public init(start: Double, end: Double, speaker: String) { self.start = start; self.end = end; self.speaker = speaker }
    }

    /// A voice already named, with a clip of 2 to 10 seconds of it as WAV.
    public struct Reference: Sendable {
        public let name: String
        public let wav: Data
        public init(name: String, wav: Data) { self.name = name; self.wav = wav }
    }

    /// The speakers' turns in one audio file. Unknown voices come back with OpenAI's own letters.
    public static func turns(_ audio: Data, filename: String, mimeType: String, credential: OpenAICredential, language: String?,
                             references: [Reference], timeout: Double) async throws -> [Turn] {
        let request = request(audio, filename: filename, mimeType: mimeType, bearer: credential.bearer, language: language,
                              references: references, timeout: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let error = body["error"] as? [String: Any]
            let detail = error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            let apiKey = credential.access == .apiKey
            switch status {
            case 401, 403:
                throw OpenAIRealtime.Failure(apiKey ? "OpenAI did not accept the API key (\(detail))." : "OpenAI did not accept the ChatGPT sign-in (\(detail)). Sign in to Codex again.",
                                             code: "unauthorized")
            case 429:
                throw OpenAIRealtime.Failure(apiKey ? "OpenAI refused the request for your API account: \(detail)" : "Your ChatGPT plan's limit was reached. Try again later. \(detail)",
                                             code: "rate_limit")
            default:
                throw OpenAIRealtime.Failure("OpenAI could not find the speakers: \(detail)", code: error?["code"] as? String ?? "status_\(status)")
            }
        }
        return turns(from: body)
    }

    /// A multipart upload to the transcription endpoint. Diarization needs chunking for audio over
    /// 30 seconds; `auto` lets OpenAI split at pauses.
    static func request(_ audio: Data, filename: String, mimeType: String, bearer: String, language: String?,
                        references: [Reference], timeout: Double) -> URLRequest {
        let boundary = "reprise-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
        body += audio + Data("\r\n".utf8)
        field("model", model)
        field("response_format", "diarized_json")
        field("chunking_strategy", "auto")
        if let language, !language.isEmpty { field("language", language) }
        for reference in references.prefix(4) {
            field("known_speaker_names[]", reference.name)
            field("known_speaker_references[]", "data:audio/wav;base64," + reference.wav.base64EncodedString())
        }
        body += Data("--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func turns(from body: [String: Any]) -> [Turn] {
        (body["segments"] as? [[String: Any]] ?? []).compactMap { segment in
            guard let start = (segment["start"] as? NSNumber)?.doubleValue, let end = (segment["end"] as? NSNumber)?.doubleValue,
                  end > start, let speaker = (segment["speaker"] as? String)?.trimmingCharacters(in: .whitespaces), !speaker.isEmpty else { return nil }
            return Turn(start: start, end: end, speaker: speaker)
        }
    }

    /// Where to cut one clip per voice for later pieces: the voice's longest stretch of speech,
    /// its turns joined across pauses under a second, at most ten seconds of it, for up to four
    /// voices in the order they first speak. Under two seconds is too short to know a voice by.
    public static func referenceSpans(_ turns: [Turn], limit: Int = 4) -> [(speaker: String, start: Double, end: Double)] {
        var order: [String] = []
        var longest: [String: (start: Double, end: Double)] = [:]
        var run: (speaker: String, start: Double, end: Double)?
        func close() {
            guard let run else { return }
            if run.end - run.start > (longest[run.speaker].map { $0.end - $0.start } ?? 0) { longest[run.speaker] = (run.start, run.end) }
        }
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            if !order.contains(turn.speaker) { order.append(turn.speaker) }
            if let current = run, current.speaker == turn.speaker, turn.start - current.end < 1 {
                run = (current.speaker, current.start, max(current.end, turn.end))
            } else {
                close()
                run = (turn.speaker, turn.start, turn.end)
            }
        }
        close()
        return order.compactMap { speaker -> (speaker: String, start: Double, end: Double)? in
            guard let span = longest[speaker], span.end - span.start >= 2 else { return nil }
            return (speaker, span.start, min(span.end, span.start + 10))
        }.prefix(limit).map { $0 }
    }

    /// Mono 16-bit PCM WAV of samples in -1...1.
    public static func wav<Samples: Collection>(_ samples: Samples, sampleRate: Int) -> Data where Samples.Element == Float {
        let pcm = OpenAIRealtime.pcm16(samples)
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header += Data("RIFF".utf8); append(UInt32(36 + pcm.count)); header += Data("WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16)); header += Data("data".utf8); append(UInt32(pcm.count))
        return header + pcm
    }
}
