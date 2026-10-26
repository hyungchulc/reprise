import AppKit
import CoreText
import os
import XCTest
@testable import RepriseCore
@testable import Reprise

final class TextRecognitionLaneTests: XCTestCase {
    /// Capture and the background re-read share one text recognition lane. In 0.8.1-alpha.1 a
    /// background-priority request beside a capture request stalled Vision and stopped capture.
    func testCaptureAndRereadRequestsFinishTogether() async throws {
        let image = try page(count: 20)
        let finished = expectation(description: "both lanes finished"); finished.expectedFulfillmentCount = 2
        for priority in [TaskPriority.utility, .userInitiated] {
            Task.detached(priority: priority) {
                for _ in 0..<3 {
                    let text = try await CaptureImageProcessor.shared.recognizeText(in: image, languages: ["en-US", "ko-KR"])
                    XCTAssertTrue(text.contains("예산"))
                }
                finished.fulfill()
            }
        }
        await fulfillment(of: [finished], timeout: 60)
    }

    /// A Vision request that never returns must not stop capture. After the macOS 27.2 update the
    /// first one waited on the Neural Engine compiler for good, and no screen was saved (2026-10-26).
    func testScreensAreSavedWithoutTextWhileARequestHangs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-hung-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TextReadingLane(hungAfter: 1.5)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let hung = Task.detached { try await lane.run(waitingAtMost: 60) { _ in release.wait() } }
        try await Task.sleep(for: .milliseconds(100))
        let processor = CaptureImageProcessor(lane: lane, textWait: 0.3)
        // Behind the request, a capture waits only so long, and its request is then never run.
        let first = try await processor.prepare(image: try page(count: 4), root: root, cipher: testKeys.cipher,
                                                settings: CaptureSettings(), previousFingerprint: nil)
        XCTAssertEqual(first?.textRead, false)
        XCTAssertEqual(first?.text, "")
        let ran = OSAllocatedUnfairLock(initialState: false)
        _ = try? await lane.run(waitingAtMost: 0.2) { _ in ran.withLock { $0 = true } }
        // Once it has run past `hungAfter`, others are refused at once.
        try await Task.sleep(for: .seconds(1))
        let refused = Date()
        let second = try await processor.prepare(image: try page(count: 6), root: root, cipher: testKeys.cipher,
                                                 settings: CaptureSettings(), previousFingerprint: nil)
        XCTAssertEqual(second?.textRead, false)
        XCTAssertLessThan(Date().timeIntervalSince(refused), 0.25)
        XCTAssertEqual(lane.trouble?.failures, 3)
        for path in [first?.imagePath, second?.imagePath].compactMap({ $0 }) {
            XCTAssertTrue(VaultCipher.isSealed(fileAt: root.appendingPathComponent(path)), path)
        }
        // When the request returns, reading works again and the trouble clears.
        release.signal()
        try await hung.value
        let text = try await processor.recognizeText(in: try page(count: 4), languages: ["en-US", "ko-KR"])
        XCTAssertTrue(text.contains("예산"))
        XCTAssertNil(lane.trouble)
        XCTAssertFalse(ran.withLock { $0 })
    }

    private func page(count: Int) throws -> CGImage {
        let width = 2400, height = 1500
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<count {
            let line = row.isMultiple(of: 2) ? "오늘 회의에서 예산 초안을 검토했다 \(row)" : "Reviewed the quarterly forecast \(row)"
            context.textPosition = CGPoint(x: 40, y: height - 70 - row * 60)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 32)])), context)
        }
        return try XCTUnwrap(context.makeImage())
    }
}
