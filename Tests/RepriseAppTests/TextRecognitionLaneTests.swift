import AppKit
import CoreText
import XCTest
@testable import Reprise

final class TextRecognitionLaneTests: XCTestCase {
    /// Capture and the background re-read share one text recognition lane. In 0.8.1-alpha.1 a
    /// background-priority request beside a capture request stalled Vision and stopped capture.
    func testCaptureAndRereadRequestsFinishTogether() async throws {
        let width = 2400, height = 1500
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<20 {
            let line = row.isMultiple(of: 2) ? "오늘 회의에서 예산 초안을 검토했다 \(row)" : "Reviewed the quarterly forecast \(row)"
            context.textPosition = CGPoint(x: 40, y: height - 70 - row * 60)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 32)])), context)
        }
        let image = try XCTUnwrap(context.makeImage())
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
}
