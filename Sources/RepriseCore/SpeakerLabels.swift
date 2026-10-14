import Foundation

/// A stretch of audio one voice holds, from on-device speaker detection.
public struct SpeakerTurn: Sendable, Equatable {
    public let start: Double
    public let end: Double
    /// The detector's own number for the voice; it carries no order.
    public let speaker: Int
    public init(start: Double, end: Double, speaker: Int) {
        self.start = start; self.end = end; self.speaker = speaker
    }
}

/// Puts speaker names on a transcript's segments and into its text.
public enum SpeakerLabels {
    public static func defaultName(_ number: Int) -> String { "Speaker \(number)" }

    /// Each segment gets the voice heard most while it was said. Voices are numbered in the order
    /// they first speak, so the first voice in the recording is Speaker 1. A segment that no turn
    /// covers takes a turn that ends or starts within a second of it, and otherwise stays unlabeled.
    public static func assign(_ turns: [SpeakerTurn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let turns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        guard !turns.isEmpty else { return segments }
        var voices: [Int?] = segments.map { segment in
            var heard: [Int: Double] = [:]
            for turn in turns where turn.end > segment.start && turn.start < segment.end {
                heard[turn.speaker, default: 0] += min(turn.end, segment.end) - max(turn.start, segment.start)
            }
            if let loudest = heard.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { return loudest.key }
            func gap(_ turn: SpeakerTurn) -> Double { max(turn.start - segment.end, segment.start - turn.end, 0) }
            guard let nearest = turns.min(by: { gap($0) < gap($1) }), gap(nearest) <= 1 else { return nil }
            return nearest.speaker
        }
        // Numbers follow the order of speaking, whatever order the segments arrived in.
        var numbers: [Int: Int] = [:]
        for index in segments.indices.sorted(by: { segments[$0].start < segments[$1].start }) {
            if let voice = voices[index], numbers[voice] == nil { numbers[voice] = numbers.count + 1 }
        }
        voices = voices.map { $0.flatMap { numbers[$0] } }
        return zip(segments, voices).map { segment, number in
            TranscriptSegment(start: segment.start, end: segment.end, text: segment.text, locale: segment.locale,
                              speaker: number.map(defaultName))
        }
    }

    /// The transcript as text. With speakers, a line that starts a new speaker begins with the name.
    public static func text(_ segments: [TranscriptSegment]) -> String {
        guard segments.contains(where: { $0.speaker != nil }) else { return segments.map(\.text).joined(separator: "\n") }
        var current: String?
        return segments.map { segment in
            defer { current = segment.speaker ?? current }
            guard let speaker = segment.speaker, speaker != current else { return segment.text }
            return "\(speaker): \(segment.text)"
        }.joined(separator: "\n")
    }

    /// Speakers in the order they first speak.
    public static func speakers(in segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        return segments.sorted { $0.start < $1.start }.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    /// A name the person typed for a speaker: one line, at most 40 characters.
    public static func cleanName(_ name: String) -> String? {
        let line = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(40))
    }

    /// Gives every segment of one speaker a new name. Naming a speaker after another one merges the two.
    public static func rename(_ speaker: String, to name: String, in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard let name = cleanName(name), name != speaker else { return segments }
        return segments.map { segment in
            guard segment.speaker == speaker else { return segment }
            return TranscriptSegment(start: segment.start, end: segment.end, text: segment.text, locale: segment.locale, speaker: name)
        }
    }
}
