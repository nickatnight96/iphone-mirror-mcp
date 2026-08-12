import CoreGraphics
import XCTest
@testable import MirrorCore

final class TextMatchTests: XCTestCase {
    func element(_ text: String, y: CGFloat) -> OCRElement {
        OCRElement(text: text, confidence: 0.9, box: CGRect(x: 10, y: y, width: 100, height: 20))
    }

    func testRankingExactThenPrefixThenContains() {
        let elements = [
            element("My Settings Panel", y: 10),
            element("Settings and more", y: 30),
            element("Settings", y: 50),
        ]
        let matches = TextMatch.find("settings", in: elements)
        XCTAssertEqual(matches.map(\.text), ["Settings", "Settings and more", "My Settings Panel"])
    }

    func testExactModeOnlyReturnsEqual() {
        let elements = [element("Settings", y: 10), element("Settings and more", y: 30)]
        let matches = TextMatch.find("settings", in: elements, exact: true)
        XCTAssertEqual(matches.map(\.text), ["Settings"])
    }

    func testStableTopToBottomOrderWithinRank() {
        let elements = [element("Sign in", y: 100), element("Sign in", y: 20)]
        let matches = TextMatch.find("sign in", in: elements)
        // Preserves given order (callers pass elements in reading order).
        XCTAssertEqual(matches.map(\.box.minY), [100, 20])
    }

    func testNoMatchAndEmptyQuery() {
        let elements = [element("Hello", y: 10)]
        XCTAssertTrue(TextMatch.find("goodbye", in: elements).isEmpty)
        XCTAssertTrue(TextMatch.find("   ", in: elements).isEmpty)
    }

    func testCenter() {
        let e = element("X", y: 40)
        XCTAssertEqual(e.center, CGPoint(x: 60, y: 50))
    }
}

final class ReadingOrderTests: XCTestCase {
    func element(_ text: String, x: CGFloat, y: CGFloat) -> OCRElement {
        OCRElement(text: text, confidence: 0.9, box: CGRect(x: x, y: y, width: 50, height: 14))
    }

    func testRowsSortTopToBottomThenLeftToRight() {
        let ordered = MirrorOCR.readingOrder([
            element("c", x: 300, y: 4),
            element("d", x: 10, y: 40),
            element("a", x: 10, y: 6),
            element("b", x: 150, y: 2),
        ])
        // y 2/4/6 share the 16px row bucket → sorted by x; y 40 comes last.
        XCTAssertEqual(ordered.map(\.text), ["a", "b", "c", "d"])
    }

    func testChainedYValuesStillProduceDeterministicOrder() {
        // A y-chain (0, 10, 20, 30) breaks tolerance-based comparators;
        // bucketed rows stay transitive and deterministic.
        let elements = (0..<4).map { element("e\($0)", x: 0, y: CGFloat($0 * 10)) }
        let ordered = MirrorOCR.readingOrder(elements.shuffled())
        XCTAssertEqual(ordered.map(\.text), ["e0", "e1", "e2", "e3"])
    }
}

final class VisionGeometryTests: XCTestCase {
    func testNormalizedBottomLeftToPixelTopLeft() {
        // A box occupying the top-left quadrant in Vision's normalized space
        // (bottom-left origin): x 0–0.5, y 0.5–1.0.
        let normalized = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        let pixels = VisionGeometry.pixelRect(
            fromNormalized: normalized,
            imageSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testFullFrame() {
        let pixels = VisionGeometry.pixelRect(
            fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: CGSize(width: 100, height: 50)
        )
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 100, height: 50))
    }
}
