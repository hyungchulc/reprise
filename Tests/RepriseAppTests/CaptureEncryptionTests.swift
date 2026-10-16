import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import RepriseCore
@testable import Reprise

final class CaptureEncryptionTests: XCTestCase {
    func testCapturedScreensReachTheDiskOnlySealed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.5, 0.8, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        let prepared = try await CaptureImageProcessor().prepare(image: try XCTUnwrap(context.makeImage()), root: root, cipher: testKeys.cipher,
                                                                  settings: CaptureSettings(), previousFingerprint: nil)
        let capture = try XCTUnwrap(prepared)
        for path in [capture.imagePath, capture.thumbnailPath] {
            let url = root.appendingPathComponent(path)
            XCTAssertTrue(VaultCipher.isSealed(fileAt: url), path)
            let data = try testKeys.cipher.contents(of: url)
            XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, path)
            var mode = stat()
            XCTAssertEqual(lstat(url.path, &mode), 0)
            XCTAssertEqual(mode.st_mode & 0o777, 0o600, path)
        }
        let shown = await ImageCache.shared.image(url: root.appendingPathComponent(capture.thumbnailPath), cipher: testKeys.cipher, maxPixels: 200)
        XCTAssertNotNil(shown)
        let foreign = await ImageCache.shared.image(url: root.appendingPathComponent(capture.imagePath), cipher: VaultKeys.ephemeral().cipher, maxPixels: 300)
        XCTAssertNil(foreign)
    }

    func testMenuBarChangesAloneDoNotMakeANewScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-menubar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func screen(bar: Double, body: Double) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(colorSpace: space, components: [body, body, body, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            context.setFillColor(CGColor(colorSpace: space, components: [bar, 0.2, 0.2, 1])!)
            context.fill(CGRect(x: 0, y: 380, width: 640, height: 20))
            return try XCTUnwrap(context.makeImage())
        }
        let processor = CaptureImageProcessor()
        let first = try await processor.prepare(image: screen(bar: 0.1, body: 0.5), root: root, cipher: testKeys.cipher,
                                                settings: CaptureSettings(), previousFingerprint: nil, ignoringTopRows: 20)
        let fingerprint = try XCTUnwrap(first).fingerprint
        let barOnly = try await processor.prepare(image: screen(bar: 0.9, body: 0.5), root: root, cipher: testKeys.cipher,
                                                  settings: CaptureSettings(), previousFingerprint: fingerprint, ignoringTopRows: 20)
        XCTAssertNil(barOnly, "A change inside the menu bar alone counts as the same screen")
        let content = try await processor.prepare(image: screen(bar: 0.9, body: 0.6), root: root, cipher: testKeys.cipher,
                                                  settings: CaptureSettings(), previousFingerprint: fingerprint, ignoringTopRows: 20)
        XCTAssertNotNil(content, "A change below the menu bar is a new screen")
        // The saved screen and its thumbnail leave the menu bar out.
        let saved = try XCTUnwrap(first)
        for (path, size) in [(saved.imagePath, (640, 380)), (saved.thumbnailPath, (400, 237))] {
            let image = try XCTUnwrap(CGImageSourceCreateWithData(try testKeys.cipher.contents(of: root.appendingPathComponent(path)) as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(image.width, size.0, path); XCTAssertEqual(image.height, size.1, path)
            XCTAssertLessThan(abs(try topLeft(image).red - 128), 12, "\(path) starts below the menu bar")
        }
    }

    /// Screens saved with their menu bar are shown without it.
    func testAScreenShownWithoutItsMenuBar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-older-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.5, 0.5, 0.5, 1])!); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!); context.fill(CGRect(x: 0, y: 380, width: 640, height: 20))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = root.appendingPathComponent("older.png")
        try testKeys.cipher.write(data as Data, to: url)
        let loaded = await ImageCache.shared.image(url: url, cipher: testKeys.cipher, maxPixels: 640, topCrop: 20.0 / 400)
        let shown = try XCTUnwrap(loaded)
        let image = try XCTUnwrap(shown.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(image.height, 380)
        XCTAssertEqual(try topLeft(image).red, 128, accuracy: 2)
    }

    private func topLeft(_ image: CGImage) throws -> (red: Int, green: Int, blue: Int) {
        var pixel = [UInt8](repeating: 0, count: 4 * image.width * image.height)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 4 * image.width,
                                              space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}
