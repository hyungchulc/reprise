import Foundation

/// The meeting assistant's look into the library: a few memories for some keywords, as short
/// excerpts labeled for citing.
public enum AssistantMemory {
    public struct Found: Sendable {
        /// What the model reads: one excerpt per memory, each starting with its label.
        public let text: String
        public let moments: [(label: String, moment: Moment)]
    }

    /// Each term is searched on its own; memories from one window within a few minutes count once.
    public static func search(_ store: MomentStore, terms: [String], days: Int? = nil, firstLabel: Int = 1, limit: Int = 6,
                              now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) async throws -> Found {
        let since = days.map { now.addingTimeInterval(-Double(max(1, $0)) * 86_400) }
        var found: [String: Moment] = [:]
        var scores: [String: Double] = [:]
        func add(_ rows: [Moment], weight: Double, order: Int) {
            for (rank, moment) in rows.enumerated() {
                found[moment.id] = moment
                scores[moment.id, default: 0] += weight / Double(rank + 10) + 0.01 / Double(order + 1)
            }
        }
        for (index, term) in terms.prefix(4).enumerated() {
            let rows = try await store.search(MomentQuery(text: term, since: since, limit: 30))
            add(rows, weight: 1, order: index)
            // Every word of a phrase must match; when none does as a whole, its words count on their own, for less.
            let words = term.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
            guard rows.isEmpty, words.count > 1 else { continue }
            for word in words.prefix(4) {
                add(try await store.search(MomentQuery(text: word, since: since, limit: 15)), weight: 0.4, order: index)
            }
        }
        let ranked = found.values.sorted {
            let a = scores[$0.id, default: 0], b = scores[$1.id, default: 0]
            return a != b ? a > b : $0.timestamp > $1.timestamp
        }
        var chosen: [Moment] = []
        for moment in ranked where !chosen.contains(where: {
            $0.appName == moment.appName && $0.windowTitle == moment.windowTitle && abs($0.timestamp.timeIntervalSince(moment.timestamp)) < 300
        }) {
            chosen.append(moment)
            if chosen.count == limit { break }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let labeled = chosen.enumerated().map { (label: "M\(firstLabel + $0.offset)", moment: $0.element) }
        let excerpts = labeled.map { item -> String in
            let moment = item.moment
            let page = moment.url.map { " | " + BrowserAddress.short($0) } ?? ""
            let kind = moment.kind == "meeting" ? "meeting transcript" : "screen"
            let text = moment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(item.label)] \(formatter.string(from: moment.timestamp)) | \(kind) | \(String(moment.appName.prefix(40))) | \(String(moment.windowTitle.prefix(120)))\(page)\n\(String(text.prefix(700)))"
        }
        return Found(text: excerpts.isEmpty ? "No memories matched these keywords." : excerpts.joined(separator: "\n\n"), moments: labeled)
    }
}
