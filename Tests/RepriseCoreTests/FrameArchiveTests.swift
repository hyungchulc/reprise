import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RepriseCore

final class FrameArchiveTests: XCTestCase {
    private let colors: [(Double, Double, Double)] = [(0.9, 0.2, 0.1), (0.1, 0.7, 0.2), (0.2, 0.3, 0.9)]

    func testArchivedScreensStayViewableSearchableAndDeletable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        let captures = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-7_200)
        for (index, color) in colors.enumerated() {
            try write(color: color, width: 320, height: 200, to: captures.appendingPathComponent("s\(index).heic"))
            try write(color: color, width: 40, height: 25, to: captures.appendingPathComponent("s\(index)-thumb.heic"))
            try await store.insert(Moment(id: "s\(index)", timestamp: old.addingTimeInterval(Double(index) * 3), appName: "Editor",
                                          text: "archived screen \(index)", imagePath: "captures/s\(index).heic",
                                          thumbnailPath: "captures/s\(index)-thumb.heic", byteCount: 10_000))
        }
        // New captures are sealed; stills from before encryption are not yet.
        XCTAssertTrue(try testKeys.cipher.sealFile(at: captures.appendingPathComponent("s1.heic")))
        let archiver = FrameArchiver(store: store, root: root)
        let report: FrameArchiver.Report
        do { report = try await archiver.archiveDue(quality: FrameArchive.balancedQuality, minimumBatch: 1) }
        catch let error as FrameArchive.Failure where ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("HEVC encoding is unavailable on this runner: \(error.localizedDescription)")
        }
        XCTAssertEqual(report.frames.count, 3)
        for index in colors.indices {
            let moment = try await store.moment(id: "s\(index)")
            XCTAssertEqual(moment?.imagePath, "")
            XCTAssertEqual(moment?.archivedFrame?.offset, Double(index))
            XCTAssertTrue(moment?.hasScreenImage == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: captures.appendingPathComponent("s\(index).heic").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: captures.appendingPathComponent("s\(index)-thumb.heic").path))
        }
        let archivedOne = try await store.moment(id: "s1")
        let movie = try XCTUnwrap(archivedOne?.archivedFrame?.path)
        XCTAssertTrue(VaultCipher.isSealed(fileAt: root.appendingPathComponent(movie)), "Archive movies are sealed as they are written")
        try await assertFrame(of: "s1", in: store, matches: colors[1])
        let found = try await store.search(MomentQuery(text: "archived screen"))
        XCTAssertEqual(Set(found.map(\.id)), ["s0", "s1", "s2"])

        // Deleting a screen re-encodes the shared movie without it.
        try await store.delete(ids: ["s1"], purgeArchivedFrames: true)
        let moved = try await archiver.purgeDeletedFrames(quality: FrameArchive.balancedQuality)
        XCTAssertEqual(Set(moved.keys), ["s0", "s2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(movie).path))
        let shifted = try await store.moment(id: "s2")
        XCTAssertEqual(shifted?.archivedFrame?.offset, 1)
        try await assertFrame(of: "s2", in: store, matches: colors[2])
        let pending = try await store.pendingArchivePurges()
        XCTAssertTrue(pending.isEmpty)

        // Only unreferenced leftovers are swept.
        let orphan = captures.appendingPathComponent("orphan.heic")
        try write(color: colors[0], width: 32, height: 20, to: orphan)
        let past = Date().addingTimeInterval(-7_200)
        for file in [orphan, captures.appendingPathComponent("s0-thumb.heic")] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        }
        _ = try await store.removeUnreferencedMedia()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captures.appendingPathComponent("s0-thumb.heic").path))
    }

    private func assertFrame(of id: String, in store: MomentStore, matches color: (Double, Double, Double), file: StaticString = #filePath, line: UInt = #line) async throws {
        let moment = try await store.moment(id: id)
        let frame = try XCTUnwrap(moment?.archivedFrame, file: file, line: line)
        let movie = try await store.mediaURL(frame.path)
        let image = try await FrameReader(movie: movie, cipher: testKeys.cipher).image(at: frame.offset)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        for (channel, expected) in [color.0, color.1, color.2].enumerated() {
            XCTAssertEqual(Double(pixel[channel]) / 255, expected, accuracy: 0.06, "channel \(channel)", file: file, line: line)
        }
    }

    private func write(color: (Double, Double, Double), width: Int, height: Int, to url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [color.0, color.1, color.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

final class FrameArchiveSampleTests: XCTestCase {
    /// Measures archiving on copies of real captures; the source folder is only read.
    func testArchiveRealCapturesWhenRequested() async throws {
        guard let source = ProcessInfo.processInfo.environment["REPRISE_ARCHIVE_SAMPLE"] else {
            throw XCTSkip("Set REPRISE_ARCHIVE_SAMPLE to a captures folder to measure archiving on real screens.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-sample-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MomentStore(root: root, keys: testKeys)
        let captures = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: source), includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "heic" && !$0.lastPathComponent.contains("-thumb") }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            .suffix(150)
        var stillBytes: Int64 = 0
        for (index, file) in files.enumerated() {
            let name = "f\(index).heic"
            try FileManager.default.copyItem(at: file, to: captures.appendingPathComponent(name))
            stillBytes += FrameArchiver.fileSize(file) ?? 0
            try await store.insert(Moment(id: "f\(index)", timestamp: Date().addingTimeInterval(-7_200 + Double(index) * 3), appName: "Sample",
                                          imagePath: "captures/\(name)", byteCount: FrameArchiver.fileSize(file) ?? 0))
        }
        let started = Date()
        let report = try await FrameArchiver(store: store, root: root).archiveDue(quality: FrameArchive.balancedQuality, minimumBatch: 1)
        let seconds = Date().timeIntervalSince(started)
        let movies = Set(report.frames.values.map(\.videoPath))
        let movieBytes = movies.reduce(Int64(0)) { $0 + (FrameArchiver.fileSize(root.appendingPathComponent($1)) ?? 0) }
        var decodes: [Double] = []
        for id in ["f0", "f37", "f74", "f111", "f149"] {
            guard let frame = report.frames[id] else { continue }
            let reader = FrameReader(movie: root.appendingPathComponent(frame.videoPath), cipher: testKeys.cipher)
            let begin = Date()
            _ = try await reader.image(at: frame.offset)
            decodes.append(Date().timeIntervalSince(begin) * 1000)
        }
        print(String(format: "ARCHIVE frames %d in %d movies, stills %.1f MB -> movies %.1f MB (%.1fx), %.1f s, decode ms %@",
                     report.frames.count, movies.count, Double(stillBytes) / 1e6, Double(movieBytes) / 1e6,
                     Double(stillBytes) / Double(max(1, movieBytes)), seconds, decodes.map { String(format: "%.0f", $0) }.joined(separator: "/")))
        XCTAssertEqual(report.frames.count, files.count)
    }
}

final class LibraryMigrationSampleTests: XCTestCase {
    /// Opens a copy of a real library (made with sqlite3 .backup) to check this version's migration.
    func testCopiedLibraryMigratesWhenRequested() async throws {
        guard let copy = ProcessInfo.processInfo.environment["REPRISE_LIBRARY_COPY"] else {
            throw XCTSkip("Set REPRISE_LIBRARY_COPY to a backed-up library.sqlite to check migration on real data.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: copy), to: root.appendingPathComponent("library.sqlite"))
        let started = Date()
        let store = try MomentStore(root: root, keys: testKeys)
        let converting = Date().timeIntervalSince(started)
        XCTAssertTrue(store.convertedFromPlaintext)
        XCTAssertFalse(MomentStore.isPlaintextDatabase(root.appendingPathComponent("library.sqlite").path))
        let stats = try await store.stats()
        let due = try await store.archivableFrames(before: Date().addingTimeInterval(-FrameArchiver.delay), limit: 5_000)
        let latest = try await store.query(MomentQuery(limit: 1))
        let word = latest.first?.text.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count > 3 }).map(String.init) ?? "the"
        let found = try await store.search(MomentQuery(text: word, limit: 5))
        print("MIGRATE memories \(stats.momentCount), archivable \(due.count), search '\(word)' \(found.count), encrypted in \(String(format: "%.2f", converting)) s")
        XCTAssertGreaterThan(stats.momentCount, 0)
        XCTAssertFalse(found.isEmpty)
        var mode = stat()
        XCTAssertEqual(lstat(root.path, &mode), 0)
        XCTAssertEqual(mode.st_mode & 0o777, 0o700)
        let reopened = try MomentStore(root: root, keys: testKeys)
        let again = try await reopened.stats()
        XCTAssertEqual(again.momentCount, stats.momentCount)
    }
}
