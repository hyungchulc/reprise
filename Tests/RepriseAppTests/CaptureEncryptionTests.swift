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
}
