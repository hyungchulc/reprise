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
}

// Serial actor bounds image encoding and Vision to the single caller-owned frame.
actor CaptureImageProcessor {
    /// `ignoringTopRows` covers the menu bar. Its clock and live status items change on their own, so
    /// they neither make a screen new nor enter the searchable text; the saved image still shows them.
    func prepare(image: CGImage, root: URL, cipher: VaultCipher, settings: CaptureSettings, previousFingerprint: String?,
                 ignoringTopRows: Int = 0) throws -> PreparedCapture? {
        try autoreleasepool {
            let timestamp = Date()
            guard let pixels = image.dataProvider?.data else { throw CaptureFailure("Unable to read captured image.") }
            let band = min(max(0, ignoringTopRows), image.height - 1)
            let data = pixels as Data
            let fingerprint = SHA256.hash(data: data[(data.startIndex + min(data.count, band * image.bytesPerRow))...])
                .map { String(format: "%02x", $0) }.joined()
            if fingerprint == previousFingerprint { return nil }
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1 - Double(band) / Double(image.height))
            var ocrWarning: String?
            do {
                let supported = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = settings.ocrLanguages.filter { supported.contains($0) }
                if request.recognitionLanguages.isEmpty { request.recognitionLanguages = ["en-US"] }
                let ocrImage = resized(image, maxDimension: 2400) ?? image
                try VNImageRequestHandler(cgImage: ocrImage).perform([request])
            } catch {
                ocrWarning = "Image saved, OCR unavailable: \(error.localizedDescription)"
            }
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
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
                                       imagePath: imagePath, thumbnailPath: thumbnailPath, byteCount: bytes)
            } catch {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(imagePath))
                try? FileManager.default.removeItem(at: root.appendingPathComponent(thumbnailPath))
                throw error
            }
        }
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
