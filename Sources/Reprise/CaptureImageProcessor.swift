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
    func prepare(image: CGImage, root: URL, settings: CaptureSettings, previousFingerprint: String?) throws -> PreparedCapture? {
        try autoreleasepool {
            let timestamp = Date()
            guard let pixels = image.dataProvider?.data else { throw CaptureFailure("Unable to read captured image.") }
            let fingerprint = SHA256.hash(data: pixels as Data).map { String(format: "%02x", $0) }.joined()
            if fingerprint == previousFingerprint { return nil }
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
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
            let thumbnailPath = "captures/\(id)-thumb.jpg"
            do {
                if !encode(image, to: root.appendingPathComponent(imagePath), type: .heic, quality: quality) {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(imagePath))
                    imagePath = "captures/\(id).jpg"
                    guard encode(image, to: root.appendingPathComponent(imagePath), type: .jpeg, quality: quality) else {
                        throw CaptureFailure("Unable to encode captured image.")
                    }
                }
                guard let thumbnail = resized(image, maxDimension: 400), encode(thumbnail, to: root.appendingPathComponent(thumbnailPath), type: .jpeg, quality: 0.7) else {
                    throw CaptureFailure("Unable to encode thumbnail.")
                }
                let paths = [imagePath, thumbnailPath]
                var bytes: Int64 = 0
                for path in paths {
                    let url = root.appendingPathComponent(path)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    bytes += (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
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

    private func encode(_ image: CGImage, to url: URL, type: UTType, quality: Double) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
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
