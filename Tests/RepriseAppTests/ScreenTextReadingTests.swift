import AppKit
import CoreText
import XCTest
@testable import RepriseCore
@testable import Reprise

/// Screens are read again only where they changed, and a line mostly in Latin letters keeps its Korean.
final class ScreenTextReadingTests: XCTestCase {
    private func screen(width: Int = 640, height: Int = 400, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func tiles(_ image: CGImage, top: Int = 20) throws -> TileGrid {
        try XCTUnwrap(TileGrid(image, pixels: try XCTUnwrap(image.dataProvider?.data) as Data, top: top))
    }

    func testChangesBecomeAreasCoveringEveryLineTheyTouch() throws {
        let size = CGSize(width: 640, height: 400), readable = CGRect(x: 0, y: 20, width: 640, height: 380)
        let before = try tiles(screen { _ in })
        // A typed word at x 100–140, 200–216 px from the top (Core Graphics draws from the bottom).
        let after = try tiles(screen { $0.fill(CGRect(x: 100, y: 400 - 216, width: 40, height: 16)) })
        XCTAssertEqual(before.changes(since: before), [])
        let changes = try XCTUnwrap(after.changes(since: before))
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].contains(CGRect(x: 100, y: 200, width: 40, height: 16)))
        // The word sits in a line read before; a line far below stays as it was.
        let line = ScreenTextLine(box: CGRect(x: 60 / 640.0, y: 1 - 222 / 400.0, width: 500 / 640.0, height: 28 / 400.0), text: "typing here")
        let far = ScreenTextLine(box: CGRect(x: 60 / 640.0, y: 1 - 380 / 400.0, width: 300 / 640.0, height: 24 / 400.0), text: "far below")
        let areas = try XCTUnwrap(ScreenText.readingAreas(changes, previous: [line, far], size: size, readable: readable))
        XCTAssertEqual(areas.count, 1)
        XCTAssertTrue(areas[0].contains(ScreenText.pixels(line.box, of: size)), "the whole line is read again")
        XCTAssertFalse(areas[0].intersects(ScreenText.pixels(far.box, of: size)))
        // A screen that changed nearly everywhere is read whole.
        let scrolled = try tiles(screen { $0.fill(CGRect(x: 0, y: 0, width: 640, height: 300)) })
        XCTAssertNil(ScreenText.readingAreas(try XCTUnwrap(scrolled.changes(since: before)), previous: [line, far], size: size, readable: readable))
        XCTAssertNil(try tiles(screen(width: 320) { _ in }).changes(since: before), "a different size cannot be compared")
    }

    func testLinesAreOrderedAndMisreadLinesAreRecognized() {
        let lines = [ScreenTextLine(box: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.05), text: "right"),
                     ScreenTextLine(box: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.05), text: "lower"),
                     ScreenTextLine(box: CGRect(x: 0.1, y: 0.81, width: 0.3, height: 0.05), text: "left")]
        XCTAssertEqual(ScreenText.text(lines), "left\nright\nlower")
        let korean = ScreenText.scripts(of: "ko-KR")
        XCTAssertTrue(ScreenText.looksMisread("d, 4 71| 300|| Stockholm Centra|o", confidence: 1, reading: korean))
        XCTAssertTrue(ScreenText.looksMisread("let requst = ecognize // | |", confidence: 0.3, reading: korean))
        XCTAssertTrue(ScreenText.looksMisread("10 号列上。", confidence: 0.3, reading: korean), "Chinese where only Korean is read")
        XCTAssertFalse(ScreenText.looksMisread("Settings", confidence: 0.3, reading: korean), "unsure plain text")
        XCTAssertFalse(ScreenText.looksMisread("| Name | Status | 2,400 |", confidence: 1, reading: korean), "table bars stand apart")
        XCTAssertFalse(ScreenText.looksMisread("|> claude --resume|", confidence: 1, reading: korean), "box borders at the ends")
        XCTAssertFalse(ScreenText.looksMisread("Stockholms centralstation, spår 4", confidence: 1, reading: korean))
        XCTAssertEqual(ScreenText.count("한글 text 漢字 かな", in: ScreenText.scripts(of: "ko-KR")), 2)
        XCTAssertEqual(ScreenText.count("한글 text 漢字 かな", in: ScreenText.scripts(of: "ja-JP")), 4)
        XCTAssertTrue(ScreenText.scripts(of: "sv-SE").isEmpty)
    }

    /// A page that scrolled up keeps the lines it read, moved along, and reads only what came into view.
    func testAScrolledPageReadsOnlyWhatCameIntoView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = (1...16).map { "Line \($0): 회의록 \($0)번 항목, budget review item \($0 * 7)" }
        func page(scrolled: Int, count: Int) throws -> CGImage {
            try screen(width: 2400, height: 900) { context in
                for (index, row) in rows.prefix(count).enumerated() {
                    context.textPosition = CGPoint(x: 60, y: 900 - 90 - index * 54 + scrolled)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: row, attributes: [.font: NSFont.systemFont(ofSize: 28)])), context)
                }
                // A menu bar the page scrolls under.
                context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 880, width: 2400, height: 20))
            }
        }
        let processor = CaptureImageProcessor()
        let firstResult = try await processor.prepare(image: try page(scrolled: 0, count: 15), root: root, cipher: testKeys.cipher,
                                                      settings: CaptureSettings(), previousFingerprint: nil, ignoringTopRows: 20)
        let first = try XCTUnwrap(firstResult)
        XCTAssertTrue(first.text.contains("Line 1:"))
        let earlier = try XCTUnwrap(first.reading?.tiles)
        let scrolledImage = try page(scrolled: 108, count: 16)
        let grid = try tiles(scrolledImage)
        XCTAssertEqual(grid.shift(in: try XCTUnwrap(grid.changes(since: earlier)?.first), since: earlier), 108)
        let secondResult = try await processor.prepare(image: scrolledImage, root: root, cipher: testKeys.cipher, settings: CaptureSettings(),
                                                       previousFingerprint: first.fingerprint, previousReading: first.reading, ignoringTopRows: 20)
        let second = try XCTUnwrap(secondResult)
        let areas = try XCTUnwrap(second.reading?.areas, "a scrolled page is not read whole")
        XCTAssertLessThan(areas.reduce(0) { $0 + $1.height }, 300, "only rows that came into view are read")
        XCTAssertTrue(second.text.contains("Line 16:"), second.text)
        XCTAssertFalse(second.text.contains("Line 1:"), "scrolled away under the menu bar")
        for number in 3...15 { XCTAssertEqual(second.text.components(separatedBy: "Line \(number):").count, 2, "Line \(number) once in \(second.text)") }
    }

    /// Reads a screen whole, then reads only the line that changed. The mixed line keeps its Korean
    /// and the Swedish line its å.
    func testOnlyTheChangedLineIsReadAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func page(_ changing: String) throws -> CGImage {
            let rows = ["오늘 회의에서 예산 초안을 검토했다", changing,
                        "형철님, 오늘 저녁 7시 30분에 Stockholm Central에서 만나요. The quick brown fox jumps over the lazy dog",
                        "Stockholms centralstation, spår 4, avgång 17:45", "다음 주 화요일까지 보고서 초안 제출"]
            return try screen(width: 2400, height: 700) { context in
                for (index, row) in rows.enumerated() {
                    context.textPosition = CGPoint(x: 60, y: 700 - 110 - index * 110)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: row, attributes: [.font: NSFont.systemFont(ofSize: 30)])), context)
                }
            }
        }
        let processor = CaptureImageProcessor()
        let first = try await processor.prepare(image: try page("Reviewed the quarterly forecast"), root: root, cipher: testKeys.cipher,
                                                settings: CaptureSettings(), previousFingerprint: nil, ignoringTopRows: 20)
        let whole = try XCTUnwrap(first)
        XCTAssertNil(whole.reading?.areas, "the first screen is read whole")
        for words in ["예산 초안", "quarterly forecast", "만나요", "spår", "화요일까지"] { XCTAssertTrue(whole.text.contains(words), "\(words) in \(whole.text)") }
        let second = try await processor.prepare(image: try page("Approved the hiring plan"), root: root, cipher: testKeys.cipher,
                                                 settings: CaptureSettings(), previousFingerprint: whole.fingerprint,
                                                 previousReading: whole.reading, ignoringTopRows: 20)
        let changed = try XCTUnwrap(second)
        XCTAssertEqual(changed.reading?.areas?.count, 1, "only the changed line is read again")
        XCTAssertTrue(changed.text.contains("hiring plan"))
        XCTAssertFalse(changed.text.contains("quarterly forecast"))
        for words in ["예산 초안", "만나요", "spår", "화요일까지"] { XCTAssertTrue(changed.text.contains(words), "\(words) kept in \(changed.text)") }
    }
}
