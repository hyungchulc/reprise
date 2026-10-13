import Foundation

public struct Moment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var timestamp: Date
    public var appName: String
    public var bundleID: String
    public var windowTitle: String
    public var text: String
    public var imagePath: String
    public var thumbnailPath: String
    public var videoPath: String?
    public var videoOffset: Double?
    public var isBookmarked: Bool
    public var kind: String
    public var byteCount: Int64
    public var audioDuration: Double?
    public var transcriptSegments: [TranscriptSegment]?
    public var transcriptionNote: String?
    public init(id: String = UUID().uuidString, timestamp: Date = Date(), appName: String, bundleID: String = "", windowTitle: String = "", text: String = "", imagePath: String = "", thumbnailPath: String = "", videoPath: String? = nil, videoOffset: Double? = nil, isBookmarked: Bool = false, kind: String = "screen", byteCount: Int64 = 0, audioDuration: Double? = nil, transcriptSegments: [TranscriptSegment]? = nil, transcriptionNote: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.appName = appName
        self.bundleID = bundleID; self.windowTitle = windowTitle; self.text = text
        self.imagePath = imagePath; self.thumbnailPath = thumbnailPath
        self.videoPath = videoPath; self.videoOffset = videoOffset
        self.isBookmarked = isBookmarked; self.kind = kind; self.byteCount = byteCount
        self.audioDuration = audioDuration; self.transcriptSegments = transcriptSegments
        self.transcriptionNote = transcriptionNote
    }
}

extension Moment {
    /// A screen memory whose pixels moved into an archive movie, addressed by frame time.
    public var archivedFrame: (path: String, offset: Double)? {
        guard kind == "screen", imagePath.isEmpty, let path = videoPath, !path.isEmpty, let offset = videoOffset else { return nil }
        return (path, offset)
    }
    public var hasScreenImage: Bool { kind == "screen" && (!imagePath.isEmpty || archivedFrame != nil) }
}

public struct TranscriptSegment: Codable, Hashable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    /// Recognizer locale that produced this text; nil for transcripts saved before multilingual support.
    public let locale: String?
    public init(start: Double, end: Double, text: String, locale: String? = nil) {
        self.start = start; self.end = end; self.text = text; self.locale = locale
    }
    public var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start && !text.isEmpty }
}

public struct MomentQuery: Sendable {
    public var text: String = ""
    public var appName: String?
    public var since: Date?
    public var until: Date?
    public var bookmarkedOnly: Bool = false
    public var kind: String?
    public var limit: Int = 100
    public var offset: Int = 0
    public init(text: String = "", appName: String? = nil, since: Date? = nil, until: Date? = nil, bookmarkedOnly: Bool = false, kind: String? = nil, limit: Int = 100, offset: Int = 0) {
        self.text = text; self.appName = appName; self.since = since; self.until = until
        self.bookmarkedOnly = bookmarkedOnly; self.kind = kind; self.limit = limit; self.offset = offset
    }
}

public struct LibraryStats: Sendable {
    public var momentCount: Int = 0
    public var storedBytes: Int64 = 0
    public var databaseBytes: Int64 = 0
    public var oldest: Date?
    public var newest: Date?
    public var apps: [String] = []
    /// Screen memories whose full image lives in a compressed video segment.
    public var archivedFrames: Int = 0
    public init() {}
}

public struct UsageEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var provider: String
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    public var durationSeconds: Double
    public var succeeded: Bool
    public init(id: String = UUID().uuidString, timestamp: Date = Date(), provider: String, model: String, inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil, durationSeconds: Double = 0, succeeded: Bool = true) {
        self.id = id; self.timestamp = timestamp; self.provider = provider; self.model = model
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costUSD = costUSD
        self.durationSeconds = durationSeconds; self.succeeded = succeeded
    }
}

public struct CaptureSettings: Codable, Equatable, Sendable {
    public var interval: Double = 3
    public var maxDimension: Int = 0
    public var imageQuality: Double = 0.85
    public var deduplicate: Bool = true
    public var pauseOnBattery: Bool = false
    public var retentionDays: Int = 30
    public var storageLimitGB: Double = 10
    public var excludedBundleIDs: [String] = ["com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop"]
    public var excludedTitleTerms: [String] = ["Private Browsing", "Incognito", "InPrivate"]
    public var ocrLanguages: [String] = ["en-US", "ko-KR"]
    /// Older screenshots move into HEVC segments; recent ones stay as still images for instant viewing.
    public var archiveOlderFrames: Bool = true
    public var archiveQuality: Double = FrameArchive.balancedQuality
    public init() {}

    // Each key falls back on its own, so a setting added in a later version never resets the others.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureSettings()
        interval = values.value(.interval, default: defaults.interval)
        maxDimension = values.value(.maxDimension, default: defaults.maxDimension)
        imageQuality = values.value(.imageQuality, default: defaults.imageQuality)
        deduplicate = values.value(.deduplicate, default: defaults.deduplicate)
        pauseOnBattery = values.value(.pauseOnBattery, default: defaults.pauseOnBattery)
        retentionDays = values.value(.retentionDays, default: defaults.retentionDays)
        storageLimitGB = values.value(.storageLimitGB, default: defaults.storageLimitGB)
        excludedBundleIDs = values.value(.excludedBundleIDs, default: defaults.excludedBundleIDs)
        excludedTitleTerms = values.value(.excludedTitleTerms, default: defaults.excludedTitleTerms)
        ocrLanguages = values.value(.ocrLanguages, default: defaults.ocrLanguages)
        archiveOlderFrames = values.value(.archiveOlderFrames, default: defaults.archiveOlderFrames)
        archiveQuality = values.value(.archiveQuality, default: defaults.archiveQuality)
    }

    /// Zero keeps the display's backing pixels; explicit limits never upscale.
    public func pixelDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let width = max(1, width), height = max(1, height)
        guard maxDimension != 0 else { return (width, height) }
        let limit = max(640, min(maxDimension, 7680))
        let scale = min(1, Double(limit) / Double(max(width, height)))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }
}

extension KeyedDecodingContainer {
    /// One stored setting, or its default when this version wrote no such key or an incompatible value.
    public func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public enum ReprisePaths {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["REPRISE_DATA_DIR"] { return URL(fileURLWithPath: custom) }
        return defaultRoot
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reprise", isDirectory: true)
    }
}
