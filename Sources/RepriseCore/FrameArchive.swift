import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Older screen memories keep their text and thumbnail rows, while full-size pixels move into
/// HEVC movies: one still per frame, frame i presented at i seconds. Screen content barely
/// changes between captures, so a movie needs roughly a sixth of the space of HEIC stills.
public enum FrameArchive {
    public static let balancedQuality = 0.65
    static let keyFrameInterval = 30
    static let directory = "archive"

    public enum Failure: LocalizedError {
        case encoderUnavailable
        case writeFailed(String)
        case frameUnavailable
        public var errorDescription: String? {
            switch self {
            case .encoderUnavailable: return "HEVC encoding is unavailable on this Mac."
            case .writeFailed(let reason): return "Could not write the screen archive: \(reason)"
            case .frameUnavailable: return "The archived screen frame could not be decoded."
            }
        }
    }

    /// Pixel size from the image header, without decoding pixels.
    public static func pixelSize(of image: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 2, height >= 2 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Encodes stills of one pixel size in order. Returns the indices of the stills that became
    /// frames 0, 1, 2...; unreadable stills are skipped and stay where they are.
    public static func write(_ stills: [URL], size: CGSize, to destination: URL, quality: Double) async throws -> [Int] {
        let width = Int(size.width) & ~1, height = Int(size.height) & ~1
        let session = try Session(destination: destination, width: width, height: height, quality: quality)
        var written: [Int] = []
        do {
            for (index, still) in stills.enumerated() {
                try Task.checkCancellation()
                guard let buffer = autoreleasepool(invoking: { session.pixelBuffer(drawing: still) }) else { continue }
                try await session.append(buffer, frame: written.count)
                written.append(index)
            }
            guard !written.isEmpty else { throw Failure.writeFailed("No readable screen images.") }
            try await session.finish()
            return written
        } catch {
            session.cancel()
            throw error
        }
    }

    /// Re-encodes a movie without the frames of deleted memories. Returns the kept frame times
    /// in their new order, so kept[i] is now frame i.
    public static func rewrite(_ movie: URL, keeping times: [Double], to destination: URL, quality: Double) async throws -> [Double] {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.frameUnavailable }
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.frameUnavailable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.frameUnavailable }
        let session = try Session(destination: destination, width: Int(size.width) & ~1, height: Int(size.height) & ~1, quality: quality)
        let wanted = Set(times.map { Int($0.rounded()) })
        var kept: [Double] = []
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let frame = Int(CMSampleBufferGetPresentationTimeStamp(sample).seconds.rounded())
                guard wanted.contains(frame), let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                try await session.append(buffer, frame: kept.count)
                kept.append(Double(frame))
            }
            guard reader.status == .completed else { throw reader.error ?? Failure.frameUnavailable }
            guard !kept.isEmpty else { throw Failure.writeFailed("No frames remain.") }
            try await session.finish()
            return kept
        } catch {
            reader.cancelReading()
            session.cancel()
            throw error
        }
    }

    /// A frame inside a movie, carried through URL-based image loading as `movie#t=offset`.
    public static func frameURL(movie: URL, offset: Double) -> URL {
        guard var components = URLComponents(url: movie, resolvingAgainstBaseURL: false) else { return movie }
        components.fragment = "t=\(offset)"
        return components.url ?? movie
    }

    public static func frameReference(_ url: URL) -> (movie: URL, offset: Double)? {
        guard url.isFileURL, let fragment = url.fragment, fragment.hasPrefix("t="),
              let offset = Double(fragment.dropFirst(2)), offset.isFinite, offset >= 0 else { return nil }
        return (URL(fileURLWithPath: url.path), offset)
    }

    static func movieFolder(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "\(directory)/%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One HEVC movie being written; keyframes every 30 frames bound the decode for any frame.
    private final class Session {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let width: Int
        let height: Int

        init(destination: URL, width: Int, height: Int, quality: Double) throws {
            guard width >= 2, height >= 2 else { throw Failure.writeFailed("Invalid frame size.") }
            self.width = width; self.height = height
            var color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
            // Pixels are drawn in sRGB; tag them as such where the system can say so.
            if #available(macOS 15, *) { color[AVVideoTransferFunctionKey] = AVVideoTransferFunction_IEC_sRGB }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: color,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: min(1, max(0.3, quality.isFinite ? quality : balancedQuality)),
                                                  AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                                                  AVVideoAllowFrameReorderingKey: false,
                                                  AVVideoExpectedSourceFrameRateKey: 1]
            ]
            writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw Failure.encoderUnavailable }
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.canAdd(input) else { throw Failure.encoderUnavailable }
            writer.add(input)
            guard writer.startWriting() else { throw Failure.writeFailed(writer.error?.localizedDescription ?? "Writer did not start.") }
            writer.startSession(atSourceTime: .zero)
        }

        func pixelBuffer(drawing still: URL) -> CVPixelBuffer? {
            guard let source = CGImageSourceCreateWithURL(still as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width & ~1 == width, image.height & ~1 == height else { return nil }
            var created: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) }
            else { CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created) }
            guard let buffer = created, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            // An odd edge loses one pixel instead of resampling the whole screen.
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
            return buffer
        }

        func append(_ buffer: CVPixelBuffer, frame: Int) async throws {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw Failure.writeFailed(writer.error?.localizedDescription ?? "Encoder stopped.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 1)) else {
                throw Failure.writeFailed(writer.error?.localizedDescription ?? "Frame was not accepted.")
            }
        }

        func finish() async throws {
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw Failure.writeFailed(writer.error?.localizedDescription ?? "Movie did not finish.") }
        }

        func cancel() { if writer.status == .writing { writer.cancelWriting() } }
    }
}

/// Exact-frame decoder for one archive movie. AVAssetImageGenerator decodes from the previous keyframe.
public final class FrameReader: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    public init(movie: URL, maxPixels: Int = 0) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if maxPixels > 0 { generator.maximumSize = CGSize(width: maxPixels, height: maxPixels) }
    }

    public func image(at offset: Double) async throws -> CGImage {
        let (image, actual) = try await generator.image(at: CMTime(seconds: offset, preferredTimescale: 600))
        guard abs(actual.seconds - offset) < 0.5 else { throw FrameArchive.Failure.frameUnavailable }
        return image
    }
}

/// Moves screen stills into archive movies in bounded batches, and re-encodes movies whose
/// memories were deleted so removed screens do not linger inside a shared file.
public actor FrameArchiver {
    public struct ArchivedFrame: Sendable, Hashable {
        public let videoPath: String
        public let offset: Double
    }
    public struct Report: Sendable {
        /// New locations for memories whose pixels moved.
        public var frames: [String: ArchivedFrame] = [:]
        public var savedBytes: Int64 = 0
        /// More stills were due than one batch takes.
        public var backlog = false
        /// Why a group of stills stayed as they were; the other groups still moved.
        public var failure: String?
    }

    /// Recent screens stay instant to open; older ones are rarely revisited frame by frame.
    public static let delay: TimeInterval = 15 * 60
    static let batchFrames = 600
    public static let minimumBatch = 120

    private let store: MomentStore
    private let root: URL

    public init(store: MomentStore, root: URL) {
        self.store = store
        self.root = root
    }

    public func archiveDue(quality: Double, now: Date = Date(), delay: TimeInterval = FrameArchiver.delay, minimumBatch: Int = FrameArchiver.minimumBatch) async throws -> Report {
        var report = Report()
        let due = try await store.archivableFrames(before: now.addingTimeInterval(-delay), limit: Self.batchFrames + 1)
        report.backlog = due.count > Self.batchFrames
        var groups: [(size: CGSize, items: [(moment: Moment, url: URL, bytes: Int64)])] = []
        for moment in due.prefix(Self.batchFrames) {
            let url = root.appendingPathComponent(moment.imagePath)
            guard let size = FrameArchive.pixelSize(of: url), let bytes = Self.fileSize(url) else { continue }
            if groups.last?.size != size { groups.append((size, [])) }
            groups[groups.count - 1].items.append((moment, url, bytes))
        }
        let readable = groups.reduce(0) { $0 + $1.items.count }
        // A short recording waits to grow into a fuller movie; an old backlog goes now.
        guard let oldest = groups.first?.items.first?.moment.timestamp,
              readable >= minimumBatch || now.timeIntervalSince(oldest) > delay + 3_600 else { report.backlog = false; return report }
        for group in groups {
            try Task.checkCancellation()
            let relative = FrameArchive.movieFolder(for: group.items[0].moment.timestamp) + "/\(UUID().uuidString).mov"
            let destination = root.appendingPathComponent(relative)
            let written: [Int]
            do {
                written = try await writeMovie(to: destination) { partial in
                    try await FrameArchive.write(group.items.map(\.url), size: group.size, to: partial, quality: quality)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failure = error.localizedDescription
                report.backlog = false
                continue
            }
            let share = (Self.fileSize(destination) ?? 0) / Int64(max(1, written.count))
            let entries = written.enumerated().map { frame, index in
                let item = group.items[index]
                return MomentStore.ArchiveEntry(id: item.moment.id, imagePath: item.moment.imagePath, offset: Double(frame),
                                                byteCount: thumbnailBytes(item.moment) + share)
            }
            let archived = Set(try await store.archive(entries, into: relative))
            if archived.isEmpty { try? FileManager.default.removeItem(at: destination); continue }
            for entry in entries where archived.contains(entry.id) {
                report.frames[entry.id] = ArchivedFrame(videoPath: relative, offset: entry.offset)
            }
            report.savedBytes += group.items.filter { archived.contains($0.moment.id) }.reduce(0) { $0 + $1.bytes } - share * Int64(archived.count)
        }
        return report
    }

    /// Rewrites movies that still hold frames of memories the person deleted.
    public func purgeDeletedFrames(quality: Double) async throws -> [String: ArchivedFrame] {
        var moved: [String: ArchivedFrame] = [:]
        for movie in try await store.pendingArchivePurges() {
            try Task.checkCancellation()
            let frames = try await store.frames(inArchive: movie)
            guard let source = try? await store.mediaURL(movie), !frames.isEmpty else {
                try await store.replaceArchive(movie, with: nil, moves: [])
                continue
            }
            let relative = FrameArchive.movieFolder(for: frames[0].timestamp) + "/\(UUID().uuidString).mov"
            let destination = root.appendingPathComponent(relative)
            let kept = try await writeMovie(to: destination) { partial in
                try await FrameArchive.rewrite(source, keeping: frames.compactMap(\.videoOffset), to: partial, quality: quality)
            }
            let share = (Self.fileSize(destination) ?? 0) / Int64(max(1, kept.count))
            let position = Dictionary(kept.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let moves = frames.compactMap { moment -> MomentStore.ArchiveMove? in
                guard let offset = moment.videoOffset, let index = position[offset.rounded()] else { return nil }
                return MomentStore.ArchiveMove(id: moment.id, from: offset, to: Double(index), byteCount: thumbnailBytes(moment) + share)
            }
            let updated = Set(try await store.replaceArchive(movie, with: relative, moves: moves))
            if updated.isEmpty { try? FileManager.default.removeItem(at: destination) }
            for move in moves where updated.contains(move.id) { moved[move.id] = ArchivedFrame(videoPath: relative, offset: move.to) }
        }
        return moved
    }

    /// Writes beside the destination, proves the last frame decodes, then moves it into place.
    private func writeMovie<T: Collection>(to destination: URL, _ encode: (URL) async throws -> T) async throws -> T {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = folder.appendingPathComponent(".partial-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: partial) }
        let frames = try await encode(partial)
        _ = try await FrameReader(movie: partial).image(at: Double(frames.count - 1))
        try FileManager.default.moveItem(at: partial, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return frames
    }

    private func thumbnailBytes(_ moment: Moment) -> Int64 {
        moment.thumbnailPath.isEmpty ? 0 : (Self.fileSize(root.appendingPathComponent(moment.thumbnailPath)) ?? 0)
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
