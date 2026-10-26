import Foundation
import SQLCipher
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
    /// Seals and opens this library's media files.
    public nonisolated let cipher: VaultCipher
    /// This launch converted a library from before encryption.
    public nonisolated let convertedFromPlaintext: Bool
    /// Screens saved from then on leave the menu bar out; older ones show it at the top. Nil when
    /// opened read-only.
    public nonisolated let screensWithoutMenuBarSince: Date?
    private let root: URL
    private let databaseURL: URL
    private let database: OpaquePointer
    private let rootDescriptor: Int32
    private var statements: [String: OpaquePointer] = [:]
    private var statementOrder: [String] = []
    private var cache: [String: Moment] = [:]
    private var cacheOrder: [String] = []
    private var cacheDataVersion: Int64?
    private static let columns = "id,timestamp,app_name,bundle_id,window_title,text,image_path,thumbnail_path,video_path,video_offset,bookmarked,kind,byte_count,audio_duration,transcript_segments,transcription_note,url"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Full-text rows change only with the indexed columns, not with bookmarks or archive moves.
    private static let updateTrigger = """
        AFTER UPDATE OF app_name,window_title,text,url ON moments BEGIN
            INSERT INTO moments_fts(moments_fts,rowid,app_name,window_title,text,url)
            VALUES('delete',old.rowid,old.app_name,old.window_title,old.text,old.url);
            INSERT INTO moments_fts(rowid,app_name,window_title,text,url)
            VALUES(new.rowid,new.app_name,new.window_title,new.text,new.url);
        END
        """
    private static let insertTrigger = """
        AFTER INSERT ON moments BEGIN
            INSERT INTO moments_fts(rowid,app_name,window_title,text,url)
            VALUES(new.rowid,new.app_name,new.window_title,new.text,new.url);
        END
        """
    private static let deleteTrigger = """
        AFTER DELETE ON moments BEGIN
            INSERT INTO moments_fts(moments_fts,rowid,app_name,window_title,text,url)
            VALUES('delete',old.rowid,old.app_name,old.window_title,old.text,old.url);
        END
        """

    /// Opens the encrypted library at `root`. A library from before encryption is converted first;
    /// read-only callers such as MCP wait until Reprise has done that.
    public init(root: URL, readOnly: Bool = false, keys: VaultKeys) throws {
        let requestedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        if !readOnly {
            try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
            // Screen text and transcripts are private to this account, including from other local users.
            var info = stat()
            if lstat(requestedRoot.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_mode & 0o077 != 0 {
                _ = chmod(requestedRoot.path, 0o700)
            }
        }
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
        let converting = Self.isPlaintextDatabase(sqlitePath)
        if converting {
            do {
                guard !readOnly else { throw MomentStoreError.database("Open Reprise once to finish encrypting this library, then reconnect") }
                try Self.encryptLegacyDatabase(at: sqlitePath, keys: keys)
            } catch { Darwin.close(descriptor); throw error }
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
        var withoutMenuBarSince: Date?
        do {
            try Self.unlock(connection, keys: keys)
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
                    byte_count INTEGER NOT NULL CHECK(byte_count >= 0), url TEXT, text_revision INTEGER
                );
                CREATE INDEX IF NOT EXISTS moments_time ON moments(timestamp DESC, id DESC);
                CREATE INDEX IF NOT EXISTS moments_app_time ON moments(app_name, timestamp DESC);
                CREATE INDEX IF NOT EXISTS moments_retention ON moments(bookmarked, timestamp);
                CREATE INDEX IF NOT EXISTS moments_image ON moments(image_path);
                CREATE INDEX IF NOT EXISTS moments_thumbnail ON moments(thumbnail_path);
                CREATE INDEX IF NOT EXISTS moments_video ON moments(video_path);
                CREATE VIRTUAL TABLE IF NOT EXISTS moments_fts USING fts5(
                    app_name, window_title, text, url, content='moments', content_rowid='rowid'
                );
                CREATE TRIGGER IF NOT EXISTS moments_insert \(Self.insertTrigger);
                CREATE TRIGGER IF NOT EXISTS moments_delete \(Self.deleteTrigger);
                CREATE TRIGGER IF NOT EXISTS moments_update \(Self.updateTrigger);
                CREATE INDEX IF NOT EXISTS moments_stills ON moments(timestamp) WHERE kind='screen' AND video_path IS NULL AND bookmarked=0;
                CREATE TABLE IF NOT EXISTS archive_purges (path TEXT PRIMARY KEY, requested REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS archive_compact (path TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS meeting_summaries (
                    moment_id TEXT PRIMARY KEY REFERENCES moments(id) ON DELETE CASCADE,
                    created REAL NOT NULL, summary TEXT NOT NULL
                );
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
            if !columns.contains("url") { try Self.execute(connection, "ALTER TABLE moments ADD COLUMN url TEXT") }
            // Screens read before 0.8.1 lost Korean text; NULL marks them for reading again.
            if !columns.contains("text_revision") { try Self.execute(connection, "ALTER TABLE moments ADD COLUMN text_revision INTEGER") }
            // Screens saved before their text could be read join them; the app looks for them while it runs.
            try Self.execute(connection, "CREATE INDEX IF NOT EXISTS moments_unread ON moments(timestamp DESC, id DESC) WHERE kind='screen' AND text_revision IS NULL")
            // Browser addresses joined the full-text index in 0.8; older indexes are rebuilt once.
            var index: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "PRAGMA table_info(moments_fts)", -1, &index, nil) == SQLITE_OK else {
                throw MomentStoreError.database(String(cString: sqlite3_errmsg(connection)))
            }
            var indexed = Set<String>()
            while sqlite3_step(index) == SQLITE_ROW {
                if let name = sqlite3_column_text(index, 1) { indexed.insert(String(cString: name)) }
            }
            sqlite3_finalize(index)
            if !indexed.contains("url") {
                try Self.execute(connection, "BEGIN IMMEDIATE")
                do {
                    try Self.execute(connection, """
                        DROP TRIGGER IF EXISTS moments_insert; DROP TRIGGER IF EXISTS moments_delete; DROP TRIGGER IF EXISTS moments_update;
                        DROP TABLE IF EXISTS moments_fts;
                        CREATE VIRTUAL TABLE moments_fts USING fts5(app_name, window_title, text, url, content='moments', content_rowid='rowid');
                        INSERT INTO moments_fts(moments_fts) VALUES('rebuild');
                        CREATE TRIGGER moments_insert \(Self.insertTrigger);
                        CREATE TRIGGER moments_delete \(Self.deleteTrigger);
                        CREATE TRIGGER moments_update \(Self.updateTrigger);
                        COMMIT
                        """)
                } catch { try? Self.execute(connection, "ROLLBACK"); throw error }
            }
            // Earlier libraries re-indexed text on every update, including bookmark and archive changes.
            var trigger: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='moments_update'", -1, &trigger, nil) == SQLITE_OK else {
                throw MomentStoreError.database(String(cString: sqlite3_errmsg(connection)))
            }
            let triggerSQL = sqlite3_step(trigger) == SQLITE_ROW ? sqlite3_column_text(trigger, 0).map { String(cString: $0) } : nil
            sqlite3_finalize(trigger)
            if let triggerSQL, !triggerSQL.contains("UPDATE OF") {
                try Self.execute(connection, "BEGIN IMMEDIATE")
                do {
                    try Self.execute(connection, "DROP TRIGGER moments_update; CREATE TRIGGER moments_update \(Self.updateTrigger); COMMIT")
                } catch { try? Self.execute(connection, "ROLLBACK"); throw error }
            }
            // A library's first opening by a version that saves screens without the menu bar marks
            // where they begin.
            try Self.execute(connection, """
                CREATE TABLE IF NOT EXISTS library_marks (name TEXT PRIMARY KEY, value REAL NOT NULL);
                INSERT OR IGNORE INTO library_marks VALUES ('screens_without_menu_bar', \(Date().timeIntervalSince1970));
                """)
            var mark: OpaquePointer?
            if sqlite3_prepare_v2(connection, "SELECT value FROM library_marks WHERE name='screens_without_menu_bar'", -1, &mark, nil) == SQLITE_OK,
               sqlite3_step(mark) == SQLITE_ROW {
                withoutMenuBarSince = Date(timeIntervalSince1970: sqlite3_column_double(mark, 0))
            }
            sqlite3_finalize(mark)
            for suffix in ["", "-wal", "-shm"] { _ = lchmod(sqlitePath + suffix, 0o600) }
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
        self.cipher = keys.cipher
        self.convertedFromPlaintext = converting
        self.screensWithoutMenuBarSince = withoutMenuBarSince
    }

    /// Whether `keys` open the library at `root`. Reads only; a wrong key changes nothing.
    public static func canUnlock(root: URL, keys: VaultKeys) -> Bool {
        let path = root.appendingPathComponent("library.sqlite").path
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return false
        }
        defer { sqlite3_close(connection) }
        return (try? unlock(connection, keys: keys)) != nil
    }

    /// Whether `root` holds a library that only its key can open.
    public static func isEncryptedLibrary(root: URL) -> Bool {
        let path = root.appendingPathComponent("library.sqlite").path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue, size > 0 else { return false }
        return !isPlaintextDatabase(path)
    }

    /// SQLite's plaintext header; an SQLCipher file starts with random bytes instead.
    static func isPlaintextDatabase(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    /// The key must be set before anything reads the file; a wrong key fails on the first read.
    private static func unlock(_ connection: OpaquePointer, keys: VaultKeys) throws {
        try execute(connection, "PRAGMA key = \"\(keys.databaseKey)\"")
        guard sqlite3_exec(connection, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            throw MomentStoreError.database("This library cannot be unlocked with the key in the login keychain")
        }
    }

    /// Copies a library from before encryption into an encrypted file, proves the copy holds the
    /// same rows and a sound full-text index, then swaps it into place. Until the swap the
    /// original stays untouched, so an interruption leaves a library that converts on next launch.
    private static func encryptLegacyDatabase(at path: String, keys: VaultKeys) throws {
        let encrypted = path + ".encrypting"
        for leftover in [encrypted, encrypted + "-journal", encrypted + "-wal", encrypted + "-shm"] { unlink(leftover) }
        var plain: OpaquePointer?
        // CREATE lets ATTACH make the encrypted file; the original already exists.
        guard sqlite3_open_v2(path, &plain, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let plain else {
            if let plain { sqlite3_close(plain) }
            throw MomentStoreError.database("Cannot open the library to encrypt it")
        }
        let expected: [String: Int64]
        do {
            sqlite3_busy_timeout(plain, 5_000)
            // Fold the write-ahead log into the main file so nothing is left pending beside it.
            try execute(plain, "PRAGMA wal_checkpoint(TRUNCATE)")
            expected = try rowCounts(plain)
            var attach: OpaquePointer?
            defer { sqlite3_finalize(attach) }
            guard sqlite3_prepare_v2(plain, "ATTACH DATABASE ?1 AS encrypted KEY ?2", -1, &attach, nil) == SQLITE_OK else {
                throw MomentStoreError.database(String(cString: sqlite3_errmsg(plain)))
            }
            sqlite3_bind_text(attach, 1, encrypted, -1, transient)
            sqlite3_bind_text(attach, 2, keys.databaseKey, -1, transient)
            guard sqlite3_step(attach) == SQLITE_DONE else { throw MomentStoreError.database(String(cString: sqlite3_errmsg(plain))) }
            try execute(plain, "SELECT sqlcipher_export('encrypted'); DETACH DATABASE encrypted;")
        } catch {
            sqlite3_close(plain)
            unlink(encrypted)
            throw error
        }
        sqlite3_close(plain)
        do {
            var copy: OpaquePointer?
            guard sqlite3_open_v2(encrypted, &copy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let copy else {
                if let copy { sqlite3_close(copy) }
                throw MomentStoreError.database("Cannot open the encrypted copy of the library")
            }
            defer { sqlite3_close(copy) }
            try unlock(copy, keys: keys)
            guard try rowCounts(copy) == expected, try scalar(copy, "PRAGMA quick_check") == "ok" else {
                throw MomentStoreError.database("The encrypted copy of the library did not match the original")
            }
            // A full-text index that had drifted from its rows is rebuilt rather than carried over.
            if expected["moments_fts_data"] != nil, (try? execute(copy, "INSERT INTO moments_fts(moments_fts) VALUES('integrity-check')")) == nil {
                try execute(copy, "INSERT INTO moments_fts(moments_fts) VALUES('rebuild')")
            }
            try execute(copy, "PRAGMA journal_mode=WAL")
        } catch {
            unlink(encrypted)
            throw error
        }
        _ = lchmod(encrypted, 0o600)
        guard rename(encrypted, path) == 0 else {
            let failure = String(cString: strerror(errno))
            unlink(encrypted)
            throw MomentStoreError.database("Cannot replace the library with its encrypted copy: \(failure)")
        }
        // Any log beside the old file was emptied above and belongs to the plaintext database.
        for suffix in ["-wal", "-shm"] { unlink(path + suffix) }
    }

    private static func rowCounts(_ connection: OpaquePointer) throws -> [String: Int64] {
        var tables: OpaquePointer?
        defer { sqlite3_finalize(tables) }
        guard sqlite3_prepare_v2(connection, "SELECT name FROM sqlite_master WHERE type='table' AND rootpage>0 AND name NOT LIKE 'sqlite_%'", -1, &tables, nil) == SQLITE_OK else {
            throw MomentStoreError.database(String(cString: sqlite3_errmsg(connection)))
        }
        var counts: [String: Int64] = [:]
        while sqlite3_step(tables) == SQLITE_ROW {
            guard let name = sqlite3_column_text(tables, 0).map({ String(cString: $0) }) else { continue }
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            counts[name] = Int64(try scalar(connection, "SELECT count(*) FROM \(quoted)") ?? "") ?? -1
        }
        return counts
    }

    private static func scalar(_ connection: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MomentStoreError.database(String(cString: sqlite3_errmsg(connection)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(database)
        Darwin.close(rootDescriptor)
    }

    /// `textRead` false saves a screen whose text could not be read yet; it is read in the background.
    public func insert(_ moment: Moment, textRead: Bool = true) throws {
        var moment = moment
        moment.imagePath = try normalizedMediaPath(moment.imagePath)
        moment.thumbnailPath = try normalizedMediaPath(moment.thumbnailPath)
        moment.videoPath = try moment.videoPath.map { try normalizedMediaPath($0) }
        let statement = try prepare("""
            INSERT INTO moments (\(Self.columns),text_revision) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,\(textRead ? "\(Self.textRevision)" : "NULL"))
            ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp,app_name=excluded.app_name,
                bundle_id=excluded.bundle_id,window_title=excluded.window_title,text=excluded.text,
                image_path=excluded.image_path,thumbnail_path=excluded.thumbnail_path,
                video_path=excluded.video_path,video_offset=excluded.video_offset,
                bookmarked=excluded.bookmarked,kind=excluded.kind,byte_count=excluded.byte_count,
                audio_duration=excluded.audio_duration,transcript_segments=excluded.transcript_segments,transcription_note=excluded.transcription_note,
                url=excluded.url
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
                  .text(moment.kind), .integer(max(0, moment.byteCount)), value(moment.audioDuration), value(segments), value(moment.transcriptionNote),
                  value(moment.url.flatMap(BrowserAddress.sanitized))], to: statement)
        try finish(statement)
        moment.byteCount = max(0, moment.byteCount)
        remember(moment)
    }

    /// UPDATE only: finishing transcription must never resurrect a deleted recording.
    /// The screen text recognition new captures get. Older screens are read again in the background.
    public static let textRevision = 1

    /// Screens whose text was recognized before the current revision or not read yet, newest first.
    public func screensNeedingText(limit: Int) throws -> [Moment] {
        let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE kind='screen' AND text_revision IS NULL ORDER BY timestamp DESC,id DESC LIMIT ?")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.integer(Int64(max(0, min(limit, 500))))], to: statement)
        var rows: [Moment] = []
        while try step(statement) { rows.append(readMoment(statement)) }
        return rows
    }

    /// Which of these screens wait for their text to be read, such as screens saved while text
    /// recognition did not answer, whose text arrives later.
    public func textPending(ids: [String]) throws -> Set<String> {
        let statement = try prepare("SELECT 1 FROM moments WHERE id=? AND kind='screen' AND text_revision IS NULL")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var pending = Set<String>()
        for id in Set(ids) {
            sqlite3_reset(statement)
            try bind([.text(id)], to: statement)
            if try step(statement) { pending.insert(id) }
        }
        return pending
    }

    public func screensNeedingTextCount() throws -> Int {
        let statement = try prepare("SELECT count(*) FROM moments WHERE kind='screen' AND text_revision IS NULL")
        defer { sqlite3_reset(statement) }
        guard try step(statement) else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Saves a screen's text read again, or only marks it read when `text` is nil (its image is
    /// gone). The full-text index changes only when the text did.
    public func saveRecognizedText(id: String, text: String?) throws {
        if let text {
            let update = try prepare("UPDATE moments SET text=? WHERE id=? AND kind='screen' AND text<>?")
            defer { sqlite3_reset(update); sqlite3_clear_bindings(update) }
            try bind([.text(text), .text(id), .text(text)], to: update)
            try finish(update)
        }
        let mark = try prepare("UPDATE moments SET text_revision=\(Self.textRevision) WHERE id=?")
        defer { sqlite3_reset(mark); sqlite3_clear_bindings(mark) }
        try bind([.text(id)], to: mark)
        try finish(mark)
        forget(id)
    }

    public func updateTranscript(id: String, text: String, segments: [TranscriptSegment], note: String?) throws {
        let encoded = String(decoding: try JSONEncoder().encode(segments.filter(\.isValid)), as: UTF8.self)
        let statement = try prepare("UPDATE moments SET text=?,transcript_segments=?,transcription_note=? WHERE id=? AND kind='meeting'")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.text(text), .text(encoded), value(note), .text(id)], to: statement)
        try finish(statement)
        forget(id)
    }

    /// A meeting's saved summary. The library database is encrypted, so the JSON is stored as is.
    public func summary(for id: String) throws -> MeetingSummary? {
        let statement = try prepare("SELECT summary FROM meeting_summaries WHERE moment_id=?")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.text(id)], to: statement)
        guard try step(statement) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: Data(string(statement, 0).utf8))
    }

    /// UPDATE-style: a summary is saved only while its recording still exists.
    public func saveSummary(_ summary: MeetingSummary, for id: String) throws {
        let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        let statement = try prepare("""
            INSERT INTO meeting_summaries(moment_id,created,summary) SELECT id,?,? FROM moments WHERE id=? AND kind='meeting'
            ON CONFLICT(moment_id) DO UPDATE SET created=excluded.created,summary=excluded.summary
            """)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.real(summary.created.timeIntervalSince1970), .text(encoded), .text(id)], to: statement)
        try finish(statement)
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
            \(predicate) ORDER BY bm25(moments_fts,2.0,4.0,1.0,2.0),m.timestamp DESC,m.id DESC LIMIT ? OFFSET ?
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

    /// Returns the closest captured screen, preferring the earlier one when distances tie. Timeline
    /// navigation moves through screens; recordings sit on their own lane and open only when chosen.
    public func nearest(to date: Date) throws -> Moment? {
        try refreshCacheVersion()
        var nearest: Moment?
        for (comparison, order) in [("<=", "DESC"), (">", "ASC")] {
            let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE timestamp\(comparison)? AND kind<>'meeting' ORDER BY timestamp \(order),id \(order) LIMIT 1")
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
        let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE (timestamp,id)\(op)(?,?) AND kind<>'meeting' ORDER BY timestamp \(order),id \(order) LIMIT 1")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.real(moment.timestamp.timeIntervalSince1970), .text(moment.id)], to: statement)
        return try step(statement) ? readMoment(statement) : nil
    }

    /// A contiguous, bounded window of screens on both sides, including across recording gaps.
    public func timeline(around date: Date, countPerSide: Int = 120) throws -> [Moment] {
        try refreshCacheVersion()
        var rows: [Moment] = []
        for (comparison, order) in [("<=", "DESC"), (">", "ASC")] {
            let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE timestamp\(comparison)? AND kind<>'meeting' ORDER BY timestamp \(order),id \(order) LIMIT ?")
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

    /// Shared media survives while another memory references it. With `purgeArchivedFrames`, an
    /// archive movie that still serves other memories is queued for re-encoding without these frames.
    public func delete(ids: [String], purgeArchivedFrames: Bool = false) throws {
        var media = Set<String>()
        var movies = Set<String>()
        try transaction {
            for id in Set(ids) {
                if let moment = try moment(id: id) {
                    media.formUnion([moment.imagePath, moment.thumbnailPath, moment.videoPath ?? ""].filter { !$0.isEmpty })
                    if purgeArchivedFrames, let frame = moment.archivedFrame { movies.insert(frame.path) }
                }
                try run("DELETE FROM moments WHERE id=?", [.text(id)])
            }
            media = try media.filter { try !isReferenced($0) }
            for movie in movies where !media.contains(movie) {
                try run("INSERT OR IGNORE INTO archive_purges(path,requested) VALUES(?,?)", [.text(movie), .real(Date().timeIntervalSince1970)])
            }
        }
        for id in ids { forget(id) }
        for path in media { removeMedia(path) }
    }

    public struct ArchiveEntry: Sendable {
        public let id: String
        public let imagePath: String
        public let offset: Double
        public let byteCount: Int64
        public init(id: String, imagePath: String, offset: Double, byteCount: Int64) {
            self.id = id; self.imagePath = imagePath; self.offset = offset; self.byteCount = byteCount
        }
    }

    public struct ArchiveMove: Sendable {
        public let id: String
        public let from: Double
        public let to: Double
        public let byteCount: Int64
        public init(id: String, from: Double, to: Double, byteCount: Int64) {
            self.id = id; self.from = from; self.to = to; self.byteCount = byteCount
        }
    }

    /// Recorded screen stills old enough to archive, oldest first. Bookmarks, imports and
    /// meetings keep their original files.
    public func archivableFrames(before date: Date, limit: Int) throws -> [Moment] {
        let statement = try prepare("""
            SELECT \(Self.columns) FROM moments WHERE kind='screen' AND video_path IS NULL AND bookmarked=0
            AND timestamp<? AND image_path LIKE 'captures/%' ORDER BY timestamp,id LIMIT ?
            """)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.real(date.timeIntervalSince1970), .integer(Int64(max(0, min(limit, 5_000))))], to: statement)
        var rows: [Moment] = []
        while try step(statement) { rows.append(readMoment(statement)) }
        return rows
    }

    /// Points stills at their frames in one transaction, then deletes the stills nothing else
    /// references. Rows changed or deleted since selection are left alone. Returns archived IDs.
    public func archive(_ entries: [ArchiveEntry], into videoPath: String) throws -> [String] {
        let movie = try normalizedMediaPath(videoPath)
        var archived: [String] = []
        var released = Set<String>()
        try transaction {
            for entry in entries {
                try run("""
                    UPDATE moments SET image_path='',video_path=?,video_offset=?,byte_count=?
                    WHERE id=? AND image_path=? AND video_path IS NULL AND kind='screen'
                    """, [.text(movie), .real(entry.offset), .integer(max(0, entry.byteCount)), .text(entry.id), .text(entry.imagePath)])
                if sqlite3_changes(database) > 0 { archived.append(entry.id); released.insert(entry.imagePath) }
            }
            released = try released.filter { try !isReferenced($0) }
        }
        for id in archived { forget(id) }
        for path in released { removeMedia(path) }
        return archived
    }

    public func pendingArchivePurges() throws -> [String] {
        try selectedIDs("SELECT path FROM archive_purges ORDER BY requested,path LIMIT 64", [])
    }

    public func frames(inArchive videoPath: String) throws -> [Moment] {
        let statement = try prepare("SELECT \(Self.columns) FROM moments WHERE video_path=? AND kind='screen' AND image_path='' ORDER BY video_offset,id")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.text(videoPath)], to: statement)
        var rows: [Moment] = []
        while try step(statement) { rows.append(readMoment(statement)) }
        return rows
    }

    /// Moves frames into a re-encoded movie and settles the purge request. The old movie is
    /// deleted once no memory references it. A `compact` movie, or one that replaces a compact
    /// movie, is marked so it is never reduced again. Returns the moved IDs.
    @discardableResult
    public func replaceArchive(_ oldPath: String, with newPath: String?, moves: [ArchiveMove], compact: Bool = false) throws -> [String] {
        let replacement = try newPath.map { try normalizedMediaPath($0) }
        var moved: [String] = []
        var unreferenced = false
        try transaction {
            if let replacement {
                for move in moves {
                    try run("UPDATE moments SET video_path=?,video_offset=?,byte_count=? WHERE id=? AND video_path=? AND video_offset=? AND image_path=''",
                            [.text(replacement), .real(move.to), .integer(max(0, move.byteCount)), .text(move.id), .text(oldPath), .real(move.from)])
                    if sqlite3_changes(database) > 0 { moved.append(move.id) }
                }
                try run("INSERT OR IGNORE INTO archive_compact(path) SELECT ? WHERE ? OR EXISTS (SELECT 1 FROM archive_compact WHERE path=?)",
                        [.text(replacement), .integer(compact ? 1 : 0), .text(oldPath)])
            }
            try run("DELETE FROM archive_purges WHERE path=?", [.text(oldPath)])
            unreferenced = try !isReferenced(oldPath)
            if unreferenced { try run("DELETE FROM archive_compact WHERE path=?", [.text(oldPath)]) }
        }
        for id in moved { forget(id) }
        if unreferenced { removeMedia(oldPath) }
        return moved
    }

    /// Movies whose screens are all older than the cutoff and not yet reduced, oldest first.
    /// Movies waiting for a purge are left to the purge.
    public func compactableArchives(before date: Date, limit: Int) throws -> [String] {
        try run("DELETE FROM archive_compact WHERE path NOT IN (SELECT video_path FROM moments WHERE video_path IS NOT NULL)")
        return try selectedIDs("""
            SELECT video_path FROM moments WHERE kind='screen' AND image_path='' AND video_path IS NOT NULL
            AND video_path NOT IN (SELECT path FROM archive_compact) AND video_path NOT IN (SELECT path FROM archive_purges)
            GROUP BY video_path HAVING MAX(timestamp)<? ORDER BY MIN(timestamp) LIMIT ?
            """, [.real(date.timeIntervalSince1970), .integer(Int64(max(1, min(limit, 64))))])
    }

    /// Records a movie that is already small enough, or that cannot be reduced, so it is not tried again.
    public func markCompact(_ path: String) throws {
        try run("INSERT OR IGNORE INTO archive_compact(path) VALUES(?)", [.text(path)])
    }

    /// JPEG thumbnails written before HEIC thumbnails, oldest first.
    public func legacyThumbnails(limit: Int) throws -> [(id: String, path: String)] {
        let statement = try prepare("SELECT id,thumbnail_path FROM moments WHERE thumbnail_path LIKE 'captures/%-thumb.jpg' ORDER BY timestamp,id LIMIT ?")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.integer(Int64(max(1, min(limit, 5_000))))], to: statement)
        var rows: [(id: String, path: String)] = []
        while try step(statement) { rows.append((string(statement, 0), string(statement, 1))) }
        return rows
    }

    /// Points a memory at its re-encoded thumbnail, then deletes the old file once nothing uses it.
    @discardableResult
    public func replaceThumbnail(id: String, from oldPath: String, to newPath: String, byteDelta: Int64) throws -> Bool {
        let replacement = try normalizedMediaPath(newPath)
        var changed = false, unreferenced = false
        try transaction {
            try run("UPDATE moments SET thumbnail_path=?,byte_count=MAX(0,byte_count+?) WHERE id=? AND thumbnail_path=?",
                    [.text(replacement), .integer(byteDelta), .text(id), .text(oldPath)])
            changed = sqlite3_changes(database) > 0
            unreferenced = try !isReferenced(oldPath)
        }
        if changed { forget(id) }
        if unreferenced { removeMedia(oldPath) }
        return changed
    }

    /// A vault file URL for readers that need one, such as AVFoundation. The path may not leave
    /// the vault or pass through a link, and must name a regular file.
    public func mediaURL(_ path: String) throws -> URL {
        let clean = try normalizedMediaPath(path)
        guard !clean.isEmpty else { throw MomentStoreError.invalidMediaPath(path) }
        let url = root.appendingPathComponent(clean)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw MomentStoreError.invalidMediaPath(path) }
        return url
    }

    /// Removes capture and archive files no memory references, such as leftovers of an interrupted
    /// capture or archive pass. Recent files are skipped: a capture writes media just before its row.
    @discardableResult
    public func removeUnreferencedMedia(olderThan age: TimeInterval = 3_600) throws -> Int64 {
        let cutoff = Date().addingTimeInterval(-max(600, age))
        var reclaimed: Int64 = 0
        // An empty or replaced database is not evidence that every file is abandoned.
        guard try storedBytes() > 0 else { return 0 }
        for directory in ["captures", FrameArchive.directory] {
            let base = root.appendingPathComponent(directory, isDirectory: true)
            guard let files = FileManager.default.enumerator(atPath: base.path) else { continue }
            while let name = files.nextObject() as? String {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(name).path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let modified = attributes[.modificationDate] as? Date, modified < cutoff else { continue }
                let relative = "\(directory)/\(name)"
                guard try !isReferenced(relative) else { continue }
                removeMedia(relative)
                reclaimed += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return reclaimed
    }

    /// Every media path a memory points at.
    public func referencedMedia() throws -> Set<String> {
        Set(try selectedIDs("SELECT image_path FROM moments UNION SELECT thumbnail_path FROM moments UNION SELECT video_path FROM moments WHERE video_path IS NOT NULL", []))
            .subtracting([""])
    }

    private func isReferenced(_ path: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM moments WHERE image_path=? OR thumbnail_path=? OR video_path=? LIMIT 1")
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind([.text(path), .text(path), .text(path)], to: statement)
        return try step(statement)
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
        let archived = try prepare("SELECT COUNT(*) FROM moments WHERE kind='screen' AND image_path='' AND video_path IS NOT NULL")
        defer { sqlite3_reset(archived); sqlite3_clear_bindings(archived) }
        if try step(archived) { result.archivedFrames = Int(sqlite3_column_int64(archived, 0)) }
        let apps = try prepare("SELECT DISTINCT app_name FROM moments ORDER BY app_name COLLATE NOCASE,app_name")
        defer { sqlite3_reset(apps); sqlite3_clear_bindings(apps) }
        while try step(apps) { result.apps.append(string(apps, 0)) }
        result.databaseBytes = databaseFileBytes()
        return result
    }

    /// `known` brought up to date with the moments saved after its newest one, read through the
    /// time index instead of the whole table. Deletions, archiving and moments dated earlier show
    /// up at the next full `stats()`.
    public func stats(after known: LibraryStats) throws -> LibraryStats {
        guard let newest = known.newest else { return try stats() }
        var result = known
        let added = try prepare("SELECT COUNT(*),COALESCE(SUM(byte_count),0),MAX(timestamp) FROM moments WHERE timestamp>?")
        defer { sqlite3_reset(added); sqlite3_clear_bindings(added) }
        sqlite3_bind_double(added, 1, newest.timeIntervalSince1970)
        if try step(added), sqlite3_column_int64(added, 0) > 0 {
            result.momentCount += Int(sqlite3_column_int64(added, 0))
            result.storedBytes += sqlite3_column_int64(added, 1)
            result.newest = Date(timeIntervalSince1970: sqlite3_column_double(added, 2))
            let apps = try prepare("SELECT DISTINCT app_name FROM moments WHERE timestamp>?")
            defer { sqlite3_reset(apps); sqlite3_clear_bindings(apps) }
            sqlite3_bind_double(apps, 1, newest.timeIntervalSince1970)
            var names = Set(result.apps)
            while try step(apps) { names.insert(string(apps, 0)) }
            if names.count != result.apps.count {
                result.apps = names.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
            }
        }
        result.databaseBytes = databaseFileBytes()
        return result
    }

    private func databaseFileBytes() -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
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

    /// Korean attaches particles to words (회의에서, 회의를), so a word also matches the longer
    /// words it starts; very short Latin words stay exact so they do not match half the index.
    static func matchTerm(_ token: String) -> String {
        let ascii = token.unicodeScalars.allSatisfy(\.isASCII)
        return token.count >= (ascii ? 4 : 2) ? "\"\(token)\"*" : "\"\(token)\""
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
            values.append(.text(tokens.map(Self.matchTerm).joined(separator: " AND ")))
        } else if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conditions.append("0")
        }
        if let app = query.appName { conditions.append("\(prefix)app_name=?"); values.append(.text(app)) }
        if let since = query.since { conditions.append("\(prefix)timestamp>=?"); values.append(.real(since.timeIntervalSince1970)) }
        if let until = query.until { conditions.append("\(prefix)timestamp<=?"); values.append(.real(until.timeIntervalSince1970)) }
        if query.bookmarkedOnly { conditions.append("\(prefix)bookmarked=1") }
        if let kind = query.kind { conditions.append("\(prefix)kind=?"); values.append(.text(kind)) }
        if query.screensOnly { conditions.append("\(prefix)kind<>'meeting'") }
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
            transcriptionNote: sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : string(statement, 15),
            url: sqlite3_column_type(statement, 16) == SQLITE_NULL ? nil : string(statement, 16))
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
        return VaultCipher.isSealed(data) ? try cipher.open(data) : data
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
