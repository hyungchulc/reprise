import Foundation

/// A piece of recognized speech with the recognizer's timing and confidence, when reported.
/// Untimed pieces, such as spaces and punctuation, attach to the surrounding phrase.
public struct RecognizedSpeech: Sendable, Equatable {
    public var text: String
    public var start: Double?
    public var end: Double?
    public var confidence: Double?
    public init(text: String, start: Double? = nil, end: Double? = nil, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

/// Reconciles transcripts of one recording made by several single-language recognizers.
/// Every recognizer hears the whole recording. For each stretch of speech the phrases with
/// the most confident coverage win, so a mixed-language meeting keeps each speaker's words.
public enum TranscriptMerge {
    /// Silence that ends a phrase; recognizers leave shorter gaps between words.
    static let phrasePause = 0.7
    static let longestPhrase = 12.0
    /// Recognizers place word edges differently, so neighbors may share this much audio.
    static let overlapTolerance = 0.25

    struct Phrase: Equatable {
        var start: Double
        var end: Double
        var text: String
        var locale: String
        var confidenceTime = 0.0
        var timedDuration = 0.0
        var confidence: Double { timedDuration > 0 ? confidenceTime / timedDuration : 0.5 }
        /// Long, confident speech outweighs short or doubtful fragments from another language.
        var weight: Double { max(0.01, end - start) * pow(min(1, max(0.05, confidence)), 2) }
    }

    /// With `joinRows` off, each phrase stays a segment of its own, so speakers can be told apart
    /// before `rows` joins them.
    public static func segments(_ candidates: [(locale: String, speech: [RecognizedSpeech])], joinRows: Bool = true) -> [TranscriptSegment] {
        let chosen = select(candidates.flatMap { phrases(from: $0.speech, locale: $0.locale) })
        guard joinRows else { return chosen.map { TranscriptSegment(start: $0.start, end: max($0.end, $0.start + 0.001), text: $0.text, locale: $0.locale) } }
        return coalesce(chosen)
    }

    /// Readable rows from short segments: neighbors of one language and one speaker share a row
    /// up to 30 seconds, as `coalesce` does for phrases.
    public static func rows(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var rows: [TranscriptSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let last = rows.last, last.locale == segment.locale, last.speaker == segment.speaker,
               segment.start - last.end <= 1.5, segment.end - last.start <= 30 {
                rows[rows.count - 1] = TranscriptSegment(start: last.start, end: max(last.end, segment.end),
                                                         text: last.text + joiner(for: segment.locale ?? "") + segment.text,
                                                         locale: last.locale, speaker: last.speaker)
            } else { rows.append(segment) }
        }
        return rows
    }

    /// Languages written without spaces between words join pieces directly.
    public static func joiner(for locale: String) -> String {
        let language = Locale(identifier: locale).language.languageCode?.identifier ?? ""
        return ["ja", "zh", "yue", "th", "lo", "km", "my"].contains(language) ? "" : " "
    }

    static func phrases(from speech: [RecognizedSpeech], locale: String) -> [Phrase] {
        var result: [Phrase] = []
        var current: Phrase?
        var leading = ""
        func close() {
            if var phrase = current {
                phrase.text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !phrase.text.isEmpty { result.append(phrase) }
            }
            current = nil
        }
        for piece in speech {
            // Recognizers also time stray punctuation across the other language's speech; only words carry time.
            let spoken = piece.text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            if !spoken, !piece.text.allSatisfy(\.isWhitespace) {
                if let phrase = current, phrase.text.trimmingCharacters(in: .whitespaces).last?.isPunctuation == false {
                    current?.text += piece.text.trimmingCharacters(in: .whitespaces)
                }
                if let phrase = current, phrase.end - phrase.start >= 1, endsSentence(piece.text) { close() }
                continue
            }
            if spoken, let start = piece.start, let end = piece.end, start.isFinite, end.isFinite, start >= 0, end >= start {
                if let phrase = current, start - phrase.end > phrasePause || end - phrase.start > longestPhrase { close() }
                var phrase = current ?? Phrase(start: start, end: end, text: leading, locale: locale)
                if current == nil { leading = "" }
                let duration = max(end - start, 0.01)
                phrase.text += piece.text
                phrase.end = max(phrase.end, end)
                phrase.confidenceTime += min(1, max(0, piece.confidence ?? 0.5)) * duration
                phrase.timedDuration += duration
                current = phrase
            } else if current != nil {
                current?.text += piece.text
            } else if spoken {
                leading += piece.text
            }
            if let phrase = current, phrase.end - phrase.start >= 1, endsSentence(piece.text) { close() }
        }
        close()
        return result
    }

    /// Weighted interval scheduling: the heaviest set of phrases whose audio does not overlap.
    static func select(_ phrases: [Phrase]) -> [Phrase] {
        let sorted = phrases.sorted { ($0.end, $0.start, $0.locale) < ($1.end, $1.start, $1.locale) }
        var best = [Double](repeating: 0, count: sorted.count + 1)
        var compatible = [Int](repeating: 0, count: sorted.count)
        for (index, phrase) in sorted.enumerated() {
            var low = 0, high = index
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle].end <= phrase.start + overlapTolerance { low = middle + 1 } else { high = middle }
            }
            compatible[index] = low
            best[index + 1] = max(best[index], phrase.weight + best[low])
        }
        var chosen: [Phrase] = []
        var index = sorted.count
        while index > 0 {
            let phrase = sorted[index - 1]
            if phrase.weight + best[compatible[index - 1]] >= best[index - 1] {
                chosen.append(phrase)
                index = compatible[index - 1]
            } else { index -= 1 }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// Readable transcript rows: one language's neighboring phrases share a row up to 30 seconds.
    static func coalesce(_ phrases: [Phrase]) -> [TranscriptSegment] {
        var rows: [Phrase] = []
        for phrase in phrases {
            if var last = rows.last, last.locale == phrase.locale, phrase.start - last.end <= 1.5, phrase.end - last.start <= 30 {
                last.text += joiner(for: phrase.locale) + phrase.text
                last.end = max(last.end, phrase.end)
                rows[rows.count - 1] = last
            } else { rows.append(phrase) }
        }
        return rows.map { TranscriptSegment(start: $0.start, end: max($0.end, $0.start + 0.001), text: $0.text, locale: $0.locale) }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".?!。？！…".contains(last)
    }
}

/// Meeting-transcription language choices, stored as BCP 47 identifiers.
public enum SpeechLanguageSelection {
    /// One app can keep this many speech languages installed at once on current macOS.
    public static let maximum = 5
    static let automaticCount = 3

    /// The languages this Mac is set up for, before any are confirmed available for speech.
    public static func defaults(preferred: [String] = Locale.preferredLanguages, current: Locale = .current) -> [String] {
        unique(preferred + [current.identifier], byLanguage: true, limit: automaticCount)
    }

    /// Normalized identifiers in order, without repeats.
    public static func unique(_ identifiers: [String], byLanguage: Bool = false, limit: Int = maximum) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for identifier in identifiers {
            let locale = Locale(identifier: identifier)
            let normalized = locale.identifier(.bcp47)
            guard !normalized.isEmpty, normalized != "und" else { continue }
            let key = byLanguage ? (locale.language.languageCode?.identifier ?? normalized) : normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
            if result.count == limit { break }
        }
        return result
    }

    /// The recognizer locale for a choice: the same locale, then the same language and region,
    /// then the language's most common region, e.g. ko-US becomes ko-KR.
    public static func resolve(_ identifier: String, supported: [String]) -> String? {
        let wanted = Locale(identifier: identifier)
        let key = wanted.identifier(.bcp47).lowercased()
        let candidates = supported.map { (id: $0, locale: Locale(identifier: $0)) }
        if let exact = candidates.first(where: { $0.locale.identifier(.bcp47).lowercased() == key }) { return exact.id }
        guard let language = wanted.language.languageCode?.identifier else { return nil }
        let sameLanguage = candidates.filter { $0.locale.language.languageCode?.identifier == language }
        if let region = wanted.region?.identifier, let match = sameLanguage.first(where: { $0.locale.region?.identifier == region }) { return match.id }
        let likely = Locale(identifier: Locale.Language(identifier: language).maximalIdentifier).region?.identifier
        if let likely, let match = sameLanguage.first(where: { $0.locale.region?.identifier == likely }) { return match.id }
        return sameLanguage.map(\.id).sorted().first
    }
}
