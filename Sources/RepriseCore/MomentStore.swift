import Foundation
import CSQLite
import Darwin

public enum MomentStoreError: Error, LocalizedError {
    case database(String)
    case invalidMediaPath(String)
    public var errorDescription: String? {
        switch self {
        case .database(let message): return "Library database: \(message)"
        case .invalidMediaPath(let path): return "Unsafe library media path: \(path)"
        }
    }
}

public actor MomentStore {
    private let root: URL
    private let databaseURL: URL
    private let database: OpaquePointer
    private let rootDescriptor: Int32
    private var statements: [String: OpaquePointer] = [:]
    private var statementOrder: [String] = []
    private var cache: [String: Moment] = [:]
    private var cacheOrder: [String] = []
    private var cacheDataVersion: Int64?
    private static let columns = "id,timestamp,app_name,bundle_id,window_title,text,image_path,thumbnail_path,video_path,video_offset,bookmarked,kind,byte_count,audio_duration,transcript_segments,transcription_note"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL, readOnly: Bool = false) throws {
        let requestedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        if !readOnly { try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true) }
        // SQLite NOFOLLOW checks parent components too; Foundation may abbreviate /private/var to /var.
        guard let physicalRoot = realpath(requestedRoot.path, nil) else { throw MomentStoreError.invalidMediaPath(requestedRoot.path) }
        let sqlitePath = String(cString: physicalRoot) + "/library.sqlite"
        let root = requestedRoot
        free(physicalRoot)
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MomentStoreError.invalidMediaPath(root.path) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            var info = stat()
            let result = (databaseURL.path + suffix).withCString { lstat($0, &info) }
            if result == 0 && (info.st_mode & S_IFMT) != S_IFREG {
                Darwin.close(descriptor)
                throw MomentStoreError.invalidMediaPath(databaseURL.path + suffix)
            }
        }
        var connection: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(sqlitePath, &connection, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open library"
            if let connection { sqlite3_close(connection) }
            Darwin.close(descriptor)
            throw MomentStoreError.database(message)
        }
        sqlite3_busy_timeout(connection, 5_000)
        do {
            if readOnly {
                try Self.execute(connection, "PRAGMA query_only=ON")
                var schema: OpaquePointer?
                defer { sqlite3_finalize(schema) }
                guard sqlite3_prepare_v2(connection, "SELECT \(Self.columns) FROM moments LIMIT 0", -1, &schema, nil) == SQLITE_OK else {
                    throw MomentStoreError.database("Open this library in the current Reprise app before connecting MCP")
                }
            } else {
            try Self.execute(connection, """
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=NORMAL;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS moments (
                    id TEXT PRIMARY KEY, timestamp REAL NOT NULL, app_name TEXT NOT NULL,
                    bundle_id TEXT NOT NULL, window_title TEXT NOT NULL, text TEXT NOT NULL,
                    image_path TEXT NOT NULL, thumbnail_path TEXT NOT NULL, video_path TEXT,
                    video_offset REAL, bookmarked INTEGER NOT NULL, kind TEXT NOT NULL,
                    byte_count INTEGER NOT NULL CHECK(byte_count >= 0)
                );
                CREATE INDEX IF NOT EXISTS moments_time ON moments(timestamp DESC, id DESC);
                CREATE INDEX IF NOT EXISTS moments_app_time ON moments(app_name, timestamp DESC);
                CREATE INDEX IF NOT EXISTS moments_retention ON moments(bookmarked, timestamp);
                CREATE INDEX IF NOT EXISTS moments_image ON moments(image_path);
                CREATE INDEX IF NOT EXISTS moments_thumbnail ON moments(thumbnail_path);
                CREATE INDEX IF NOT EXISTS moments_video ON moments(video_path);
                CREATE VIRTUAL TABLE IF NOT EXISTS moments_fts USING fts5(
                    app_name, window_title, text, content='moments', content_rowid='rowid'
                );
                CREATE TRIGGER IF NOT EXISTS moments_insert AFTER INSERT ON moments BEGIN
                    INSERT INTO moments_fts(rowid,app_name,window_title,text)
                    VALUES(new.rowid,new.app_name,new.window_title,new.text);
                END;
                CREATE TRIGGER IF NOT EXISTS moments_delete AFTER DELETE ON moments BEGIN
                    INSERT INTO moments_fts(moments_fts,rowid,app_name,window_title,text)
                    VALUES('delete',old.rowid,old.app_name,old.window_title,old.text);
                END;
                CREATE TRIGGER IF NOT EXISTS moments_update AFTER UPDATE ON moments BEGIN
                    INSERT INTO moments_fts(moments_fts,rowid,app_name,window_title,text)
                    VALUES('delete',old.rowid,old.app_name,old.window_title,old.text);
                    INSERT INTO moments_fts(rowid,app_name,window_title,text)
                    VALUES(new.rowid,new.app_name,new.window_title,new.text);
                END;
                CREATE TABLE IF NOT EXISTS usage (
                    id TEXT PRIMARY KEY, timestamp REAL NOT NULL, provider TEXT NOT NULL,
                    model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER,
                    cost_usd REAL, duration_seconds REAL NOT NULL, succeeded INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS usage_time ON usage(timestamp DESC);
                """
            )
            // Additive migration: older recordings and their full-text index stay intact.
            var schema: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "PRAGMA table_info(moments)", -1, &schema, nil) == SQLITE_OK else {
                throw MomentStoreError.database(String(cString: sqlite3_errmsg(connection)))
            }
            var columns = Set<String>()
            while sqlite3_step(schema) == SQLITE_ROW {
                if let name = sqlite3_column_text(schema, 1) { columns.insert(String(cString: name)) }
            }
            sqlite3_finalize(schema)
            if !columns.contains("audio_duration") { try Self.execute(connection, "ALTER TABLE moments ADD COLUMN audio_duration REAL") }
            if !columns.contains("transcript_segments") { try Self.execute(connection, "ALTER TABLE moments ADD COLUMN transcript_segments TEXT") }
            if !columns.contains("transcription_note") { try Self.execute(connection, "ALTER TABLE moments ADD COLUMN transcription_note TEXT") }
            }
        } catch {
            sqlite3_close(connection)
            Darwin.close(descriptor)
            throw error
        }
        self.root = root
        self.databaseURL = databaseURL
        self.database = connection
        self.rootDescriptor = descriptor
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(database)
        Darwin.close(rootDescriptor)
    }

    public func insert(_ moment: Moment) throws {
        var moment = moment
        moment.imagePath = try normalizedMediaPath(moment.imagePath)
        moment.thumbnailPath = try normalizedMediaPath(moment.thumbnailPath)
        moment.videoPath = try moment.videoPath.map { try normalizedMediaPath($0) }
        let statement = try prepare("""
            INSERT INTO moments (\(Self.columns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp,app_name=excluded.app_name,
                bundle_id=excluded.bundle_id,window_title=excluded.window_title,text=excluded.text,
                image_path=excluded.image_path,thumbnail_path=excluded.thumbnail_path,
                video_path=excluded.video_path,video_offset=excluded.video_offset,
                bookmarked=excluded.bookmarked,kind=excluded.kind,byte_count=excluded.byte_count,
                audio_duration=excluded.audio_duration,transcript_segments=excluded.transcript_segments,transcription_note=excluded.transcription_note
            """
        )
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        moment.transcriptSegments = moment.transcriptSegments?.filter(\.isValid)
        if let duration = moment.audioDuration, !duration.isFinite || duration <= 0 { moment.audioDuration = nil }
        let segments = try moment.transcriptSegments.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try bind([.text(moment.id), .real(moment.timestamp.timeIntervalSince1970), .text(moment.appName),
                  .text(moment.bundleID), .text(moment.windowTitle), .text(moment.text),
                  .text(moment.imagePath), .text(moment.thumbnailPath), value(moment.videoPath),
                  value(moment.videoOffset), .integer(moment.isBookmarked ? 1 : 0),
                  .text(moment.kind), .integer(max(0, moment.byteCount)), value(moment.audioDuration), value(segments), value(moment.transcriptionNote)], to: statement)
        try finish(statement)
        moment.byteCount = max(0, moment.byteCount)
        remember(moment)
    }

    /// UPDATE only: finishing transcription must never resurrect a deleted recording.
    public func updateTranscript(id: String, text: String, segments: [TranscriptSegment], note: String?) throws {
        let encoded = String(decoding: try JSONEncoder().encode(segments.filter(\.isValid)), as: UTF8.self)
        let statement = try prepare("UPDATE moments SET text=?,transcript_segments=?,transcription_note=? WHERE id=? AND kind='meeting'")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.text(text), .text(encoded), value(note), .text(id)], to: statement)
        try finish(statement)
        forget(id)
    }

    public func query(_ query: MomentQuery) throws -> [Moment] {
        try refreshCacheVersion()
        let (predicate, values) = filters(query)
        let statement = try prepare("SELECT \(Self.columns) FROM moments \(predicate) ORDER BY timestamp DESC,id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values + [.integer(Int64(max(0, min(query.limit, 1_000)))), .integer(Int64(max(0, query.offset)))], to: statement)
        var moments: [Moment] = []
        while try step(statement) {
            let moment = readMoment(statement)
            moments.append(moment)
            remember(moment)
        }
        return moments
    }

    /// FTS relevance is independent of the small, newest-first timeline window.
    public func search(_ query: MomentQuery) throws -> [Moment] {
        guard !Self.tokens(query.text).isEmpty else { return try self.query(query) }
        let (predicate, values) = filters(query, prefix: "m.", textPredicate: "moments_fts MATCH ?")
        let columns = Self.columns.split(separator: ",").map { "m.\($0)" }.joined(separator: ",")
        let statement = try prepare("""
            SELECT \(columns) FROM moments m JOIN moments_fts ON moments_fts.rowid=m.rowid
            \(predicate) ORDER BY bm25(moments_fts,2.0,4.0,1.0),m.timestamp DESC,m.id DESC LIMIT ? OFFSET ?
            """)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values + [.integer(Int64(max(0, min(query.limit, 1_000)))), .integer(Int64(max(0, query.offset)))], to: statement)
        var rows: [Moment] = []
        while try step(statement) { rows.append(readMoment(statement)) }
        return rows
    }

    /// Bounded time-spread evidence, rather than filling every slot from the newest minute.
    public func sample(_ query: MomentQuery) throws -> [Moment] {
        let count = max(0, min(query.limit, 120))
        guard count > 0 else { return [] }
        let (predicate, values) = filters(query)
        let statement = try prepare("SELECT MIN(timestamp),MAX(timestamp) FROM moments \(predicate)")
        let lower: Double, upper: Double
        do {
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind(values, to: statement)
            guard try step(statement), sqlite3_column_type(statement, 0) != SQLITE_NULL else { return [] }
            lower = sqlite3_column_double(statement, 0); upper = sqlite3_column_double(statement, 1)
        }
        var rows: [Moment] = [], ids = Set<String>()
        for index in 0..<count {
            var request = query
            request.limit = 1; request.offset = 0
            let target = index == count - 1 && count > 1 ? lower : upper - (upper - lower) * Double(index) / Double(max(1, count - 1))
            request.until = Date(timeIntervalSince1970: target)
            if let row = try self.query(request).first, ids.insert(row.id).inserted { rows.append(row) }
        }
        return rows
    }

    /// Scan the complete filtered interval in SQLite, then load bounded representative media rows.
    public func activityOverview(_ query: MomentQuery) throws -> MemoryOverview {
        let limit = max(1, min(96, query.limit))
        let (predicate, values) = filters(query)
        let statement = try prepare("""
            WITH ranked AS (
                SELECT id,timestamp,
                    ROW_NUMBER() OVER (
                        PARTITION BY CAST(timestamp/900 AS INTEGER),app_name,bundle_id,window_title,kind
                        ORDER BY length(text) DESC,timestamp,id
                    ) AS source_rank,
                    COUNT(*) OVER () AS total_records,
                    MIN(timestamp) OVER () AS oldest,MAX(timestamp) OVER () AS newest
                FROM moments \(predicate)
            ), representatives AS (
                SELECT * FROM ranked WHERE source_rank=1
            ), tiled AS (
                SELECT *,NTILE(?) OVER (ORDER BY timestamp,id) AS tile,
                    COUNT(*) OVER () AS activities FROM representatives
            ), picked AS (
                SELECT *,ROW_NUMBER() OVER (
                    PARTITION BY tile ORDER BY CASE WHEN tile=? THEN -timestamp ELSE timestamp END,id
                ) AS sample_rank FROM tiled
            )
            SELECT id,total_records,activities,oldest,newest FROM picked
            WHERE sample_rank=1 ORDER BY timestamp,id
            """)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values + [.integer(Int64(limit)), .integer(Int64(limit))], to: statement)
        var moments: [Moment] = [], total = 0, activities = 0
        var oldest: Date?, newest: Date?
        while try step(statement) {
            try Task.checkCancellation()
            total = Int(sqlite3_column_int64(statement, 1)); activities = Int(sqlite3_column_int64(statement, 2))
            oldest = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            newest = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            if let moment = try self.moment(id: string(statement, 0)) { moments.append(moment) }
        }
        let coverage = oldest.flatMap { start in newest.map { end in
            MemorySearchCoverage(totalRecords: total, activityCount: activities, suppliedRecords: moments.count, oldest: start, newest: end)
        } }
        return MemoryOverview(moments: moments, coverage: coverage)
    }

    public func moment(id: String) throws -> Moment? {
        try refreshCacheVersion()
        if let moment = cache[id] { remember(moment); return moment }
        let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE id=?")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.text(id)], to: statement)
        guard try step(statement) else { return nil }
        let moment = readMoment(statement)
        remember(moment)
        return moment
    }

    public func moment(id: String, matching query: MomentQuery) throws -> Moment? {
        let (predicate, values) = filters(query)
        let join = predicate.isEmpty ? "WHERE" : "AND"
        let statement = try prepare("SELECT \(Self.columns) FROM moments \(predicate) \(join) id=? LIMIT 1")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values + [.text(id)], to: statement)
        return try step(statement) ? readMoment(statement) : nil
    }

    /// Returns the closest captured instant, preferring the earlier moment when distances tie.
    public func nearest(to date: Date) throws -> Moment? {
        try refreshCacheVersion()
        var nearest: Moment?
        for (comparison, order) in [("<=", "DESC"), (">", "ASC")] {
            let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE timestamp\(comparison)? ORDER BY timestamp \(order),id \(order) LIMIT 1")
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind([.real(date.timeIntervalSince1970)], to: statement)
            guard try step(statement) else { continue }
            let candidate = readMoment(statement)
            if let existing = nearest, abs(candidate.timestamp.timeIntervalSince(date)) >= abs(existing.timestamp.timeIntervalSince(date)) { continue }
            nearest = candidate
        }
        if let nearest { remember(nearest) }
        return nearest
    }

    public func adjacent(to moment: Moment, earlier: Bool) throws -> Moment? {
        let op = earlier ? "<" : ">"
        let order = earlier ? "DESC" : "ASC"
        let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE (timestamp,id)\(op)(?,?) ORDER BY timestamp \(order),id \(order) LIMIT 1")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.real(moment.timestamp.timeIntervalSince1970), .text(moment.id)], to: statement)
        return try step(statement) ? readMoment(statement) : nil
    }

    /// A contiguous, bounded window on both sides, including across recording gaps.
    public func timeline(around date: Date, countPerSide: Int = 120) throws -> [Moment] {
        try refreshCacheVersion()
        var rows: [Moment] = []
        for (comparison, order) in [("<=", "DESC"), (">", "ASC")] {
            let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE timestamp\(comparison)? ORDER BY timestamp \(order),id \(order) LIMIT ?")
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind([.real(date.timeIntervalSince1970), .integer(Int64(max(1, min(500, countPerSide))))], to: statement)
            while try step(statement) { rows.append(readMoment(statement)) }
        }
        return rows.sorted { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
    }

    public func timelineOverview(around date: Date, span: TimeInterval) throws -> MemoryTimelineAxis {
        try refreshCacheVersion()
        var rows: [TimelineEntry] = []
        let span = max(600, min(28_800, span))
        for (comparison, order) in [("<=", "DESC"), (">", "ASC")] {
            let statement = try prepare("SELECT id,timestamp,app_name,bundle_id,kind,audio_duration FROM moments WHERE timestamp\(comparison)? ORDER BY timestamp \(order),id \(order) LIMIT 8192")
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind([.real(date.timeIntervalSince1970)], to: statement)
            var previous = date, distance: TimeInterval = 0
            while try step(statement) {
                let time = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                rows.append(TimelineEntry(id: string(statement, 0), timestamp: time, appName: string(statement, 2),
                                          bundleID: string(statement, 3), kind: string(statement, 4),
                                          audioDuration: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5)))
                distance += MemoryTimeline.displayDuration(abs(time.timeIntervalSince(previous)))
                previous = time
                if distance >= span { break }
            }
        }
        return MemoryTimelineAxis(entries: rows)
    }

    public func skip(from moment: Moment, earlier: Bool, seconds: TimeInterval = 30) throws -> Moment? {
        let date = moment.timestamp.addingTimeInterval((earlier ? -1 : 1) * max(1, seconds))
        if let target = try nearest(to: date), earlier ? target.timestamp < moment.timestamp : target.timestamp > moment.timestamp { return target }
        return try adjacent(to: moment, earlier: earlier)
    }

    public func setBookmarked(id: String, value: Bool) throws {
        try run("UPDATE moments SET bookmarked=? WHERE id=?", [.integer(value ? 1 : 0), .text(id)])
        forget(id)
    }

    public func delete(ids: [String]) throws {
        var media = Set<String>()
        try transaction {
            for id in Set(ids) {
                if let moment = try moment(id: id) {
                    media.formUnion([moment.imagePath, moment.thumbnailPath, moment.videoPath ?? ""].filter { !$0.isEmpty })
                }
                try run("DELETE FROM moments WHERE id=?", [.text(id)])
            }
            for path in media {
                let statement = try prepare("SELECT 1 FROM moments WHERE image_path=? OR thumbnail_path=? OR video_path=? LIMIT 1")
                defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
                try bind([.text(path), .text(path), .text(path)], to: statement)
                if try step(statement) { media.remove(path) }
            }
        }
        for id in ids { forget(id) }
        for path in media { removeMedia(path) }
    }

    /// Bookmarks can keep the library above its requested budget. Nonpositive limits disable that constraint.
    public func prune(retentionDays: Int, maxBytes: Int64) throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(max(0, retentionDays)) * 86_400).timeIntervalSince1970
        var removed = 0
        if retentionDays > 0 {
            while true {
                let ids = try selectedIDs("SELECT id FROM moments WHERE bookmarked=0 AND timestamp<? ORDER BY timestamp,id LIMIT 128", [.real(cutoff)])
                guard !ids.isEmpty else { break }
                try delete(ids: ids)
                removed += ids.count
            }
        }
        if maxBytes > 0 {
            var bytes = try storedBytes()
            while bytes > maxBytes {
                let statement = try prepare("SELECT id,byte_count FROM moments WHERE bookmarked=0 ORDER BY timestamp,id LIMIT 128")
                var ids: [String] = []
                var reclaimed: Int64 = 0
                do {
                    defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
                    while try step(statement) {
                        ids.append(string(statement, 0))
                        reclaimed += sqlite3_column_int64(statement, 1)
                        if bytes - reclaimed <= maxBytes { break }
                    }
                }
                guard !ids.isEmpty else { break }
                try delete(ids: ids)
                bytes -= reclaimed
                removed += ids.count
            }
        }
        return removed
    }

    public func stats() throws -> LibraryStats {
        let statement = try prepare("SELECT COUNT(*),COALESCE(SUM(byte_count),0),MIN(timestamp),MAX(timestamp) FROM moments")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var result = LibraryStats()
        if try step(statement) {
            result.momentCount = Int(sqlite3_column_int64(statement, 0))
            result.storedBytes = sqlite3_column_int64(statement, 1)
            if sqlite3_column_type(statement, 2) != SQLITE_NULL { result.oldest = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)) }
            if sqlite3_column_type(statement, 3) != SQLITE_NULL { result.newest = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)) }
        }
        let apps = try prepare("SELECT DISTINCT app_name FROM moments ORDER BY app_name COLLATE NOCASE,app_name")
        defer { sqlite3_reset(apps); sqlite3_clear_bindings(apps) }
        while try step(apps) { result.apps.append(string(apps, 0)) }
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path + suffix)
            result.databaseBytes += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return result
    }

    public func recordUsage(_ entry: UsageEntry) throws {
        try run("""
            INSERT INTO usage VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                timestamp=excluded.timestamp,provider=excluded.provider,model=excluded.model,
                input_tokens=excluded.input_tokens,output_tokens=excluded.output_tokens,
                cost_usd=excluded.cost_usd,duration_seconds=excluded.duration_seconds,succeeded=excluded.succeeded
            """, [.text(entry.id), .real(entry.timestamp.timeIntervalSince1970), .text(entry.provider),
                    .text(entry.model), value(entry.inputTokens), value(entry.outputTokens),
                    value(entry.costUSD), .real(entry.durationSeconds), .integer(entry.succeeded ? 1 : 0)])
    }

    public func usage(since: Date?) throws -> [UsageEntry] {
        let statement = try prepare("SELECT * FROM usage \(since == nil ? "" : "WHERE timestamp>=?") ORDER BY timestamp DESC,id DESC")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        if let since { try bind([.real(since.timeIntervalSince1970)], to: statement) }
        var entries: [UsageEntry] = []
        while try step(statement) {
            entries.append(UsageEntry(id: string(statement, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                provider: string(statement, 2), model: string(statement, 3),
                inputTokens: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 4)),
                outputTokens: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 5)),
                costUSD: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                durationSeconds: sqlite3_column_double(statement, 7), succeeded: sqlite3_column_int(statement, 8) != 0))
        }
        return entries
    }

    /// Writes all matches from the requested offset as a JSON array, without loading the entire library.
    public func export(to destination: URL, query requestedQuery: MomentQuery) throws {
        let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !["", "-wal", "-shm"].contains(where: { resolvedDestination.path == databaseURL.path + $0 }) else {
            throw MomentStoreError.database("Export cannot overwrite the active library database")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".reprise-export-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try handle.write(contentsOf: Data("[".utf8))
        var query = requestedQuery
        query.limit = 1_000
        query.offset = max(0, query.offset)
        var first = true
        while true {
            let page = try self.query(query)
            for moment in page {
                if !first { try handle.write(contentsOf: Data(",".utf8)) }
                try handle.write(contentsOf: encoder.encode(moment))
                first = false
            }
            if page.count < query.limit { break }
            query.offset += page.count
        }
        try handle.write(contentsOf: Data("]".utf8))
        try handle.synchronize()
        try handle.close()
        // POSIX rename atomically replaces an existing file, including a symlink itself.
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private enum Value { case text(String), real(Double), integer(Int64), null }
    private func value(_ text: String?) -> Value { text.map(Value.text) ?? .null }
    private func value(_ number: Double?) -> Value { number.map(Value.real) ?? .null }
    private func value(_ number: Int?) -> Value { number.map { .integer(Int64($0)) } ?? .null }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MomentStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] {
            statementOrder.removeAll { $0 == sql }
            statementOrder.append(sql)
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MomentStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
        if statementOrder.count >= 64 {
            let oldest = statementOrder.removeFirst()
            if let expired = statements.removeValue(forKey: oldest) { sqlite3_finalize(expired) }
        }
        statements[sql] = statement
        statementOrder.append(sql)
        return statement
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let text): status = text.withCString { sqlite3_bind_text(statement, slot, $0, Int32(text.utf8.count), Self.transient) }
            case .real(let number): status = sqlite3_bind_double(statement, slot, number)
            case .integer(let number): status = sqlite3_bind_int64(statement, slot, number)
            case .null: status = sqlite3_bind_null(statement, slot)
            }
            guard status == SQLITE_OK else { throw MomentStoreError.database(String(cString: sqlite3_errmsg(database))) }
        }
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw MomentStoreError.database(String(cString: sqlite3_errmsg(database)))
    }

    private func finish(_ statement: OpaquePointer) throws { _ = try step(statement) }
    private func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values, to: statement)
        try finish(statement)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try Self.execute(database, "BEGIN IMMEDIATE")
        do { try body(); try Self.execute(database, "COMMIT") }
        catch { try? Self.execute(database, "ROLLBACK"); throw error }
    }

    private static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(.nonBaseCharacters).inverted).filter { !$0.isEmpty }
    }

    private func filters(_ query: MomentQuery, prefix: String = "", textPredicate: String? = nil) -> (String, [Value]) {
        var conditions: [String] = []
        var values: [Value] = []
        // Only literal Unicode word tokens enter MATCH; operators and punctuation are never FTS syntax.
        let tokens = Self.tokens(query.text)
        if !tokens.isEmpty {
            conditions.append(textPredicate ?? "\(prefix)rowid IN (SELECT rowid FROM moments_fts WHERE moments_fts MATCH ?)")
            values.append(.text(tokens.map { "\"\($0)\"" }.joined(separator: " AND ")))
        } else if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conditions.append("0")
        }
        if let app = query.appName { conditions.append("\(prefix)app_name=?"); values.append(.text(app)) }
        if let since = query.since { conditions.append("\(prefix)timestamp>=?"); values.append(.real(since.timeIntervalSince1970)) }
        if let until = query.until { conditions.append("\(prefix)timestamp<=?"); values.append(.real(until.timeIntervalSince1970)) }
        if query.bookmarkedOnly { conditions.append("\(prefix)bookmarked=1") }
        if let kind = query.kind { conditions.append("\(prefix)kind=?"); values.append(.text(kind)) }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), values)
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func readMoment(_ statement: OpaquePointer) -> Moment {
        Moment(id: string(statement, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            appName: string(statement, 2), bundleID: string(statement, 3), windowTitle: string(statement, 4),
            text: string(statement, 5), imagePath: string(statement, 6), thumbnailPath: string(statement, 7),
            videoPath: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : string(statement, 8),
            videoOffset: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 9),
            isBookmarked: sqlite3_column_int(statement, 10) != 0, kind: string(statement, 11), byteCount: sqlite3_column_int64(statement, 12),
            audioDuration: sqlite3_column_type(statement, 13) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 13),
            transcriptSegments: (try? JSONDecoder().decode([TranscriptSegment].self, from: Data(string(statement, 14).utf8)))?.filter(\.isValid),
            transcriptionNote: sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : string(statement, 15))
    }

    private func remember(_ moment: Moment) {
        cacheOrder.removeAll { $0 == moment.id }
        cacheOrder.append(moment.id)
        cache[moment.id] = moment
        if cacheOrder.count > 128 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
    private func forget(_ id: String) { cache.removeValue(forKey: id); cacheOrder.removeAll { $0 == id } }

    private func refreshCacheVersion() throws {
        let statement = try prepare("PRAGMA data_version")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        guard try step(statement) else { return }
        let version = sqlite3_column_int64(statement, 0)
        if let old = cacheDataVersion, old != version { cache.removeAll(); cacheOrder.removeAll() }
        cacheDataVersion = version
    }

    private func selectedIDs(_ sql: String, _ values: [Value]) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values, to: statement)
        var ids: [String] = []
        while try step(statement) { ids.append(string(statement, 0)) }
        return ids
    }
    private func storedBytes() throws -> Int64 {
        let statement = try prepare("SELECT COALESCE(SUM(byte_count),0) FROM moments")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        return try step(statement) ? sqlite3_column_int64(statement, 0) : 0
    }

    private func normalizedMediaPath(_ path: String) throws -> String {
        if path.isEmpty { return path }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\0"), !components.contains("..") else {
            throw MomentStoreError.invalidMediaPath(path)
        }
        let clean = components.filter { $0 != "." }.joined(separator: "/")
        let first = clean.split(separator: "/").first.map(String.init)
        guard !clean.isEmpty, first != "library.sqlite", first != "library.sqlite-wal", first != "library.sqlite-shm" else {
            throw MomentStoreError.invalidMediaPath(path)
        }
        var url = root
        for component in clean.split(separator: "/") {
            url.appendPathComponent(String(component))
            var info = stat()
            if lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                throw MomentStoreError.invalidMediaPath(path)
            }
        }
        return clean
    }

    /// Read a bounded regular file without following symlinks in any path component.
    public func readMedia(_ path: String, maxBytes: Int = 16 * 1024 * 1024) throws -> Data {
        let clean = try normalizedMediaPath(path)
        let parts = clean.split(separator: "/").map(String.init)
        guard let name = parts.last, maxBytes > 0, maxBytes <= 32 * 1024 * 1024 else { throw MomentStoreError.invalidMediaPath(path) }
        var directory = Darwin.dup(rootDescriptor)
        guard directory >= 0 else { throw MomentStoreError.invalidMediaPath(path) }
        defer { Darwin.close(directory) }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw MomentStoreError.invalidMediaPath(path) }
            Darwin.close(directory)
            directory = next
        }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw MomentStoreError.invalidMediaPath(path) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maxBytes else { throw MomentStoreError.invalidMediaPath(path) }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maxBytes else { throw MomentStoreError.invalidMediaPath(path) }
        return data
    }

    private func removeMedia(_ path: String) {
        guard let clean = try? normalizedMediaPath(path), !clean.isEmpty else { return }
        let parts = clean.split(separator: "/").map(String.init)
        var directory = Darwin.dup(rootDescriptor)
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }
        // Directory descriptors prevent a concurrently replaced ancestor symlink from escaping the root.
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return }
            Darwin.close(directory)
            directory = next
        }
        guard let name = parts.last else { return }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { return }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        _ = unlinkat(directory, name, 0)
    }
}
