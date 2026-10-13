import AppKit
import QuartzCore
import XCTest
@testable import Reprise

final class MemoryEdgeGlowTests: XCTestCase {
    @MainActor func testGradientWorkIsLimitedToThePerimeter() throws {
        let view = MemoryEdgeGlowView()
        view.frame = CGRect(x: 0, y: 0, width: 2_056, height: 1_329)
        view.configure(accent: .systemGreen, cornerRadius: 18, animated: false)
        view.layout()
        let edges = try XCTUnwrap(view.layer?.sublayers).compactMap { $0 as? CAGradientLayer }
        XCTAssertEqual(edges.count, 4)
        let area = edges.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
        XCTAssertLessThan(area, view.bounds.width * view.bounds.height * 0.05)
        for edge in edges {
            XCTAssertEqual(edge.type, .axial)
            XCTAssertEqual(edge.colors?.count, 2)
            XCTAssertTrue(edge.animationKeys()?.isEmpty ?? true)
            XCTAssertTrue(edge.filters?.isEmpty ?? true)
            XCTAssertFalse(edge.frame.contains(CGPoint(x: 1_028, y: 664)))
        }
        XCTAssertNil(view.hitTest(CGPoint(x: 1, y: 1)))
    }

    @MainActor func testOutlineKeepsSquareBottomCornersAndHollowCenter() throws {
        let view = MemoryEdgeGlowView()
        view.frame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        view.configure(accent: .systemBlue, cornerRadius: 18, animated: false)
        view.layout()
        let mask = try XCTUnwrap(view.layer?.mask)
        let outline = try XCTUnwrap(mask.sublayers?.last as? CAShapeLayer)
        let path = try XCTUnwrap(outline.path)
        XCTAssertNil(outline.fillColor)
        XCTAssertEqual(outline.lineWidth, 2)
        let border = path.copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        XCTAssertTrue(border.contains(CGPoint(x: 1, y: 698)))
        XCTAssertTrue(border.contains(CGPoint(x: 999, y: 698)))
        XCTAssertFalse(border.contains(CGPoint(x: 1, y: 1)))
        XCTAssertFalse(border.contains(CGPoint(x: 500, y: 350)))
        let original = try XCTUnwrap(view.layer?.sublayers?.first)
        view.configure(accent: .systemRed, cornerRadius: 0, animated: false)
        view.layout()
        XCTAssertTrue(view.layer?.sublayers?.first === original)
        XCTAssertTrue(try XCTUnwrap(outline.path).copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10).contains(CGPoint(x: 1, y: 2)))
    }
}
