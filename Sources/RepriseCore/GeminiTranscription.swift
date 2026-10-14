import Foundation

/// How Reprise reaches Gemini for transcription.
public enum GeminiAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case subscription, apiKey
    public var id: String { rawValue }
    public var title: String { self == .subscription ? "Google AI plan, through Antigravity" : "Gemini API key" }
}

/// Recordings transcribed by Gemini, which hears the audio itself and tells the voices apart.
/// Through Antigravity the audio is a file in its private workspace, read with its file viewer;
/// through the API it goes inline with the request.
public enum GeminiTranscription {
    /// One line as Gemini wrote it, before its end time is known.
    public struct Line: Equatable, Sendable {
        public let start: Double
        public let speaker: String?
        public let text: String
        public init(start: Double, speaker: String?, text: String) { self.start = start; self.speaker = speaker; self.text = text }
    }

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    static let schema = #"""
    {"type":"object","properties":{"segments":{"type":"array","items":{"type":"object","properties":{"start":{"type":"string","description":"When the segment starts, as M:SS from the start of the audio, or H:MM:SS past an hour"},"speaker":{"type":"string","description":"Speaker 1, Speaker 2 and so on, or empty when voices are not asked for"},"text":{"type":"string"}},"required":["start","speaker","text"]}},"unreadable":{"type":"boolean","description":"True only when the audio could not be opened or heard"}},"required":["segments"]}
    """#

    /// What Gemini is told; `language` is a language code chosen in Audio settings.
    static func instructions(speakers: Bool, language: String?) -> String {
        var rules = [
            "You transcribe a recording of a meeting or call.",
            "- Write down everything that is said, word for word, in the language it is spoken. Do not translate, summarize, correct or add anything.",
            "- Start a new segment at each sentence and whenever the voice changes.",
            "- Give each segment's start as M:SS from the start of the audio, or H:MM:SS past an hour.",
            speakers
                ? "- Tell the voices apart. Name them Speaker 1, Speaker 2 and so on, in the order they first speak, and keep each voice's name for the whole recording."
                : "- Leave speaker empty.",
            "- Leave out silence, music and noise. If nobody speaks, return no segments."
        ]
        if let language, let name = Locale(identifier: "en").localizedString(forLanguageCode: language) {
            rules.append("- Most of the speech is expected to be in \(name). Write any other language as it is spoken.")
        }
        return rules.joined(separator: "\n")
    }

    /// Transcribes one audio file: an `.m4a` through Antigravity, AAC (ADTS) through the API.
    /// `model` empty picks the light Flash model.
    public static func transcribe(_ file: URL, access: GeminiAccess, model: String, executable: String?, speakers: Bool,
                                  language: String?, timeout: Double) async throws -> (lines: [Line], model: String) {
        switch access {
        case .subscription:
            let configuration = AIProviderConfiguration(provider: .gemini, executablePath: executable)
            guard let agy = AICommand.executable(configuration) else { throw Failure("Antigravity is not installed. Install it in Audio settings.") }
            var chosen = model
            if chosen.isEmpty {
                chosen = automaticModel(await AIClient().models(configuration: configuration)) ?? ""
                guard !chosen.isEmpty else { throw Failure("Antigravity listed no Gemini model. Check its Google sign-in in Audio settings.") }
            }
            return (try lines(try await antigravity(file, executable: agy, model: chosen, speakers: speakers, language: language, timeout: timeout)), chosen)
        case .apiKey:
            guard let key = APIKeys.load(.gemini) else { throw Failure("No Gemini API key is saved. Add one in Audio settings.") }
            let chosen = model.isEmpty ? try await ProviderAPI.automaticModel(.geminiAPI, key: key) : model
            return (try lines(try await api(file, key: key, model: chosen, speakers: speakers, language: language, timeout: timeout)), chosen)
        }
    }

    /// The model Automatic uses through Antigravity: the light-thinking Flash, as for searches.
    /// Only Gemini models hear audio.
    public static func automaticModel(_ options: [AIModelOption]) -> String? {
        AIModelFamily.geminiDefault(options.filter { $0.id.hasPrefix("gemini-") })
    }

    static func antigravity(_ file: URL, executable: URL, model: String, speakers: Bool, language: String?, timeout: Double) async throws -> [String: Any] {
        let request = instructions(speakers: speakers, language: language) + """


        Open the audio file \(AIProcessRunner.workspaceToken)/\(file.lastPathComponent) with your file viewing tool and listen to all of it. \
        If it cannot be opened, call finish right away with unreadable set to true. When the transcript is complete, return the JSON \
        object by calling the finish tool once, with the object as its arguments. Use no tool other than the file viewer and finish.
        """
        let input = try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["role": "user", "content": request]]) + Data("\n".utf8)
        let arguments = AICommand.arguments(configuration: AIProviderConfiguration(provider: .gemini, model: model), schema: schema, systemPrompt: "")
        let start = Date()
        let output = try await AIProcessRunner.run(executable: executable, arguments: arguments, input: input, timeout: timeout,
                                                   provider: .gemini, attachments: [file])
        guard output.exitCode == 0 else {
            // Antigravity reports sign-in and quota failures in its event stream.
            _ = try AIResponseParser.structured(output.stdout, provider: .gemini, requestedModel: model, duration: 0, allowedTools: ["view_file"])
            throw AIProviderError.processFailed(output.exitCode)
        }
        return try AIResponseParser.structured(output.stdout, provider: .gemini, requestedModel: model,
                                               duration: Date().timeIntervalSince(start), allowedTools: ["view_file"]).payload
    }

    /// Transcription needs hearing, not reasoning, so the API is asked to think little; a model that
    /// refuses the setting is asked again without it, and one that refuses the schema, without that.
    static func api(_ file: URL, key: String, model: String, speakers: Bool, language: String?, timeout: Double) async throws -> [String: Any] {
        let audio = try Data(contentsOf: file)
        let shape = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any]
        func ask(schema: [String: Any]?, thinking: [String: Any]?) async throws -> [String: Any] {
            var request = try ProviderAPI.geminiAudioRequest(key: key, model: model, system: instructions(speakers: speakers, language: language), audio: audio,
                                                             mimeType: "audio/aac", prompt: "Transcribe this recording.", schema: schema, timeout: timeout)
            if let thinking, var body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] {
                var generation = body["generationConfig"] as? [String: Any] ?? [:]
                generation["thinkingConfig"] = thinking
                body["generationConfig"] = generation
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            return try ProviderAPI.geminiReply(try await ProviderAPI.send(request, vendor: .gemini)).payload
        }
        do {
            return try await ask(schema: shape, thinking: lightThinking(model))
        } catch AIProviderError.apiFailed(let message) where message.lowercased().contains("thinking") {
            return try await ask(schema: shape, thinking: nil)
        } catch AIProviderError.apiFailed(let message) where message.lowercased().contains("schema") {
            // A model that takes no JSON schema still answers in JSON; the instructions name the keys.
            return try await ask(schema: nil, thinking: nil)
        }
    }

    /// Gemini 3 and later take a thinking level; earlier models a budget, where Flash takes none.
    static func lightThinking(_ model: String) -> [String: Any] {
        ProviderAPI.version(model) >= 3 ? ["thinkingLevel": "low"] : ["thinkingBudget": model.contains("flash") ? 0 : 128]
    }

    /// The lines of Gemini's answer, in order.
    static func lines(_ payload: [String: Any]) throws -> [Line] {
        if payload["unreadable"] as? Bool == true { throw Failure("Gemini could not open the recording.") }
        guard let rows = payload["segments"] as? [[String: Any]] else { throw AIProviderError.invalidResponse }
        return rows.compactMap { row in
            let text = (row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = (row["start"] as? String).flatMap(seconds) ?? (row["start"] as? NSNumber)?.doubleValue ?? 0
            let speaker = (row["speaker"] as? String).flatMap(SpeakerLabels.cleanName)
            return Line(start: start, speaker: speaker, text: text)
        }
    }

    /// Seconds in a time such as "1:05", "01:02:03", "[0:07]" or "75.5".
    public static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[]() ")).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0, value.isFinite, index == 0 || value < 60 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Transcript segments for a piece that starts at `offset` and lasts `duration` seconds. Times
    /// stay in order within the piece. A segment ends where the next begins, or after about the time
    /// its words take. With `speakers`, voices are renamed Speaker 1, 2, … in the order they first
    /// speak; without, they are dropped.
    public static func segments(_ lines: [Line], offset: Double, duration: Double, speakers: Bool) -> [TranscriptSegment] {
        var starts: [Double] = []
        for line in lines { starts.append(min(max(line.start, starts.last ?? 0), duration)) }
        var names: [String: String] = [:]
        return lines.indices.map { index in
            let start = starts[index]
            let next = starts.dropFirst(index + 1).first { $0 > start } ?? duration
            let spoken = 2 + 0.35 * Double(lines[index].text.count)
            let end = max(start + 0.3, min(next, start + spoken, duration))
            var speaker: String?
            if speakers, let voice = lines[index].speaker {
                if names[voice] == nil { names[voice] = SpeakerLabels.defaultName(names.count + 1) }
                speaker = names[voice]
            }
            return TranscriptSegment(start: offset + start, end: offset + end, text: lines[index].text, speaker: speaker)
        }
    }
}
