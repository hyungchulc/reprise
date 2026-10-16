import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import RepriseCore

struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct PreparedCapture: Sendable {
    let timestamp: Date
    let fingerprint: String
    let text: String
    let ocrWarning: String?
    let imagePath: String
    let thumbnailPath: String
    let byteCount: Int64
    /// The screen's tiles and lines, so the next screen reads again only what changed. Nil when its
    /// text could not be read.
    var reading: ScreenReading? = nil
}

// Serial actor bounds image encoding and Vision to the single caller-owned frame.
/// Every Vision text request in Reprise runs on the shared instance, one at a time. Two requests at
/// once, from capture and from reading older screens again, deadlocked inside Vision and stopped
/// capture for good (0.8.1-alpha.1 and alpha.2).
actor CaptureImageProcessor {
    static let shared = CaptureImageProcessor()

    /// `ignoringTopRows` covers the menu bar. Its clock and live status items change on their own, so
    /// they neither make a screen new nor enter the searchable text; the saved image still shows them.
    /// `previousReading` is what the last saved screen held; where its tiles still match, its lines
    /// are kept and only the rest is read.
    func prepare(image: CGImage, root: URL, cipher: VaultCipher, settings: CaptureSettings, previousFingerprint: String?,
                 previousReading: ScreenReading? = nil, display: UInt32? = nil,
                 ignoringTopRows: Int = 0, textScaleLimit: Int = 2_400) throws -> PreparedCapture? {
        try autoreleasepool {
            let timestamp = Date()
            guard let pixels = image.dataProvider?.data else { throw CaptureFailure("Unable to read captured image.") }
            let band = min(max(0, ignoringTopRows), image.height - 1)
            let data = pixels as Data
            let fingerprint = SHA256.hash(data: data[(data.startIndex + min(data.count, band * image.bytesPerRow))...])
                .map { String(format: "%02x", $0) }.joined()
            if fingerprint == previousFingerprint { return nil }
            try Task.checkCancellation()
            var ocrWarning: String?
            var text = ""
            var reading: ScreenReading?
            do {
                reading = try read(image, pixels: data, band: band, languages: settings.ocrLanguages, display: display,
                                   previous: previousReading, scaleLimit: textScaleLimit)
                text = ScreenText.text(reading?.lines ?? [])
            } catch {
                ocrWarning = "Image saved, OCR unavailable: \(error.localizedDescription)"
            }
            try Task.checkCancellation()
            let directory = root.appendingPathComponent("captures", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let id = UUID().uuidString
            let quality = settings.imageQuality.isFinite ? min(1, max(0.2, settings.imageQuality)) : 0.85
            var imagePath = "captures/\(id).heic"
            var thumbnailPath = "captures/\(id)-thumb.heic"
            do {
                // Pixels are encoded in memory and reach the disk only sealed.
                var still = encode(image, type: .heic, quality: quality)
                if still == nil {
                    imagePath = "captures/\(id).jpg"
                    still = encode(image, type: .jpeg, quality: quality)
                }
                guard let still else { throw CaptureFailure("Unable to encode captured image.") }
                try cipher.write(still, to: root.appendingPathComponent(imagePath))
                guard let thumbnail = resized(image, maxDimension: 400) else { throw CaptureFailure("Unable to encode thumbnail.") }
                var small = encode(thumbnail, type: .heic, quality: 0.6)
                if small == nil {
                    thumbnailPath = "captures/\(id)-thumb.jpg"
                    small = encode(thumbnail, type: .jpeg, quality: 0.7)
                }
                guard let small else { throw CaptureFailure("Unable to encode thumbnail.") }
                try cipher.write(small, to: root.appendingPathComponent(thumbnailPath))
                var bytes: Int64 = 0
                for path in [imagePath, thumbnailPath] {
                    bytes += (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size] as? NSNumber)?.int64Value ?? 0
                }
                return PreparedCapture(timestamp: timestamp, fingerprint: fingerprint, text: text, ocrWarning: ocrWarning,
                                       imagePath: imagePath, thumbnailPath: thumbnailPath, byteCount: bytes, reading: reading)
            } catch {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(imagePath))
                try? FileManager.default.removeItem(at: root.appendingPathComponent(thumbnailPath))
                throw error
            }
        }
    }

    /// The text of a whole image, below `band` rows of menu bar.
    func recognizeText(in image: CGImage, languages: [String], ignoringTopRows band: Int = 0, textScaleLimit: Int = 2_400) throws -> String {
        let band = min(max(0, band), image.height - 1)
        return ScreenText.text(try readLines(in: image, area: CGRect(x: 0, y: band, width: image.width, height: image.height - band),
                                             languages: languages, scaleLimit: textScaleLimit))
    }

    /// Reads a screen: only the areas that changed since `previous` when it can be compared and
    /// little changed, otherwise the whole screen.
    private func read(_ image: CGImage, pixels: Data, band: Int, languages: [String], display: UInt32?,
                      previous: ScreenReading?, scaleLimit: Int) throws -> ScreenReading {
        // A pixel layout without whole bytes per pixel has no tiles, and is always read whole.
        let tiles = TileGrid(image, pixels: pixels, top: band)
        let size = CGSize(width: image.width, height: image.height)
        let top = CGFloat(min(max(0, band), image.height - 1))
        let readable = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
        if let tiles, let previous, let earlier = previous.tiles, previous.display == display, previous.languages == languages,
           let changes = tiles.changes(since: earlier),
           let areas = ScreenText.readingAreas(changes, previous: previous.lines, size: size, readable: readable) {
            // Lines the changes did not touch keep what was read before; each area is read with a
            // little room, and only lines centred inside it are taken from that reading.
            var lines = previous.lines.filter { line in !areas.contains { $0.intersects(ScreenText.pixels(line.box, of: size)) } }
            for area in areas {
                let room = area.insetBy(dx: -12, dy: -8).intersection(readable)
                lines += try readLines(in: image, area: room, languages: languages, scaleLimit: scaleLimit).filter {
                    let pixels = ScreenText.pixels($0.box, of: size)
                    return area.contains(CGPoint(x: pixels.midX, y: pixels.midY))
                }
            }
            return ScreenReading(display: display, languages: languages, tiles: tiles, lines: lines, areas: areas)
        }
        let lines = try readLines(in: image, area: readable, languages: languages, scaleLimit: scaleLimit)
        return ScreenReading(display: display, languages: languages, tiles: tiles, lines: lines, areas: nil)
    }

    /// The lines of text in `area` of an image, given in pixels with the origin at the top left.
    /// Vision reads each block in the language it detects. A fixed list read everything with its
    /// first language: English first dropped Korean, Korean first lost Swedish å, ä and ö.
    /// Language correction is off: it bends words toward a dictionary, which leaves Korean as it was
    /// at about half the cost, and keeps names and code as shown.
    func readLines(in image: CGImage, area: CGRect, languages: [String], scaleLimit: Int = 2_400) throws -> [ScreenTextLine] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = area.integral.intersection(bounds)
        guard !area.isNull, area.width >= 8, area.height >= 8, let crop = area == bounds ? image : image.cropping(to: area) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        let hints = ScreenTextLanguages.hints(languages.filter { supported.contains($0) })
        request.recognitionLanguages = hints
        try VNImageRequestHandler(cgImage: resized(crop, maxDimension: max(1_280, scaleLimit)) ?? crop).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        var lines: [(line: ScreenTextLine, confidence: Float)] = (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, !best.string.isEmpty else { return nil }
            return (ScreenTextLine(box: ScreenText.box(observation.boundingBox, in: area, of: size), text: best.string), best.confidence)
        }
        // A line mostly in Latin letters is read as Latin, which turns the Korean, Japanese or Chinese
        // in it into stray letters and bars. Such lines are read again with that language first, and
        // the new reading is kept when it holds more of that script.
        let wide = hints.filter { !ScreenText.scripts(of: $0).isEmpty }
        if !wide.isEmpty {
            var budget = 12
            for index in lines.indices where budget > 0 && ScreenText.looksMisread(lines[index].line.text, confidence: lines[index].confidence) {
                budget -= 1
                lines[index].line.text = try reread(lines[index].line, in: image, first: wide, languages: hints)
            }
        }
        return lines.map(\.line)
    }

    /// One line read again at full size with each wide-script language first in turn.
    private func reread(_ line: ScreenTextLine, in image: CGImage, first wide: [String], languages: [String]) throws -> String {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let tight = ScreenText.pixels(line.box, of: bounds.size)
        let pad = max(6, tight.height * 0.35)
        let area = tight.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
        guard !area.isNull, area.width >= 8, area.height >= 8, let crop = image.cropping(to: area) else { return line.text }
        // Only text centred on the line counts, not slivers of the lines above and below.
        let middle = (tight.midY - area.minY) / area.height
        for language in wide {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = [language] + languages.filter { $0 != language }
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let text = (request.results ?? [])
                .filter { abs((1 - $0.boundingBox.midY) - middle) < max(0.25, tight.height / area.height / 2) }
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let scripts = ScreenText.scripts(of: language)
            if ScreenText.count(text, in: scripts) > ScreenText.count(line.text, in: scripts) { return text }
        }
        return line.text
    }

    func remove(_ result: PreparedCapture, root: URL) {
        for path in [result.imagePath, result.thumbnailPath] { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
    }

    private func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func resized(_ image: CGImage, maxDimension: Int) -> CGImage? {
        guard max(image.width, image.height) > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
