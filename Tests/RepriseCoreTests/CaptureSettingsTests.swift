import XCTest
@testable import RepriseCore

final class CaptureSettingsTests: XCTestCase {
    func testNativeRetinaKeepsBackingPixels() {
        let settings = CaptureSettings()
        let size = settings.pixelDimensions(width: 4112, height: 2658)
        XCTAssertEqual(size.width, 4112)
        XCTAssertEqual(size.height, 2658)
        XCTAssertEqual(settings.imageQuality, 0.85)
    }

    func testExplicitLimitPreservesAspectAndNeverUpscales() {
        var settings = CaptureSettings()
        settings.maxDimension = 1600
        let large = settings.pixelDimensions(width: 4112, height: 2658)
        XCTAssertEqual(large.width, 1600)
        XCTAssertEqual(large.height, 1034)
        let small = settings.pixelDimensions(width: 800, height: 500)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 500)
        let portrait = settings.pixelDimensions(width: 2658, height: 4112)
        XCTAssertEqual(portrait.width, 1034)
        XCTAssertEqual(portrait.height, 1600)
    }

    func testPersistedSettingsRoundTripWithoutChangingCustomQuality() throws {
        var custom = CaptureSettings()
        custom.maxDimension = 3200
        custom.imageQuality = 0.75
        let restored = try JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(restored, custom)
        let native = try JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(CaptureSettings()))
        XCTAssertEqual(native.maxDimension, 0)
    }
}
