import Foundation

public struct SavedSearchResult: Codable, Equatable, Sendable {
    public let response: AIResponse
    public let momentIDs: [String]
    public let savedAt: Date
    public let appName: String?
    public let kind: String?
    public let day: Date?
    public let turns: [MemorySearchTurn]?

    public init(response: AIResponse, moments: [Moment], appName: String? = nil, kind: String? = nil, day: Date? = nil, savedAt: Date = Date(), turns: [MemorySearchTurn]? = nil) {
        self.response = response; self.momentIDs = moments.map(\.id); self.savedAt = savedAt
        self.appName = appName; self.kind = kind; self.day = day
        self.turns = turns.map { Array($0.suffix(12)) }
    }

    /// Read only the original evidence IDs. Never retrieve new matches or call a provider.
    public func restore(from store: MomentStore) async throws -> (response: AIResponse, moments: [Moment], turns: [MemorySearchTurn], missingCount: Int) {
        var loaded: [String: Moment] = [:], seen = Set<String>()
        let ids = (momentIDs + (turns ?? []).flatMap { $0.response.citations.map(\.momentID) }).filter { seen.insert($0).inserted }
        // Current results plus every citation from the bounded saved conversation.
        for id in ids.prefix(200 + 12 * 96) {
            try Task.checkCancellation()
            if let moment = try await store.moment(id: id) { loaded[id] = moment }
        }
        let available = Set(loaded.keys)
        let restored = AIResponse(text: response.text, citations: response.citations.filter { available.contains($0.momentID) }, usage: response.usage, coverage: response.coverage)
        let restoredTurns = (turns ?? []).map { turn in
            MemorySearchTurn(question: turn.question, response: AIResponse(text: turn.response.text,
                citations: turn.response.citations.filter { available.contains($0.momentID) }, usage: turn.response.usage, coverage: turn.response.coverage), id: turn.id)
        }
        return (restored, momentIDs.compactMap { loaded[$0] }, restoredTurns, ids.count - loaded.count)
    }
}

public struct SearchHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let query: String
        public var result: SavedSearchResult?
    }
    public private(set) var entries: [Entry] = []
    public var queries: [String] { entries.map(\.query) }
    public init() {}

    private enum CodingKeys: String, CodingKey { case entries, queries }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try values.decodeIfPresent([Entry].self, forKey: .entries)
            ?? values.decodeIfPresent([String].self, forKey: .queries)?.map { Entry(query: $0) } ?? []
        for entry in saved.prefix(3).reversed() { record(entry.query, result: entry.result) }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries, forKey: .entries)
    }

    public func result(for query: String) -> SavedSearchResult? {
        entries.first { Self.matches($0.query, query) }?.result
    }

    public mutating func record(_ query: String, result: SavedSearchResult? = nil) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 8 * 1024 else { return }
        let old = self.result(for: query)
        entries.removeAll { Self.matches($0.query, query) }
        let bounded = result.flatMap { value -> SavedSearchResult? in
            guard value.momentIDs.count <= 200, value.response.citations.count <= 200, (value.turns?.count ?? 0) <= 12,
                  (value.turns ?? []).allSatisfy({ $0.question.utf8.count <= 8 * 1024 && $0.response.citations.count <= 96 }),
                  let data = try? JSONEncoder().encode(value), data.count <= 1_024 * 1_024 else { return nil }
            return value
        }
        entries.insert(Entry(query: query, result: bounded ?? old), at: 0)
        entries = Array(entries.prefix(3))
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Saved answers quote memories, so the file is sealed like the rest of the library. A file
    /// from before encryption is read once and sealed on the next save.
    public static func load(root: URL, cipher: VaultCipher) -> SearchHistory {
        let url = root.appendingPathComponent("search-history.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1_024 * 1_024,
              let data = try? cipher.contents(of: url),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    public func save(root: URL, cipher: VaultCipher) throws {
        try cipher.write(try JSONEncoder().encode(self), to: root.appendingPathComponent("search-history.json"))
    }
}
