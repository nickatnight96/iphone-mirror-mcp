import CoreGraphics
import XCTest
@testable import MirrorCore

final class WindowGeometryTests: XCTestCase {
    // A window at (100, 50), 410x740 points, captured at 2x → 820x1480 pixels.
    let geometry = WindowGeometry(
        windowID: 42,
        boundsPoints: CGRect(x: 100, y: 50, width: 410, height: 740),
        imagePixelSize: CGSize(width: 820, height: 1480)
    )

    func testOriginPixelMapsToWindowOrigin() throws {
        let p = try geometry.screenPoint(fromPixelX: 0, pixelY: 0)
        XCTAssertEqual(p, CGPoint(x: 100, y: 50))
    }

    func testFarCornerClampsJustInsideWindow() throws {
        // The inclusive far edge is accepted but clamped half a pixel inward
        // so the click cannot land outside the window.
        let p = try geometry.screenPoint(fromPixelX: 820, pixelY: 1480)
        XCTAssertEqual(p, CGPoint(x: 509.75, y: 789.75))
        XCTAssertLessThan(p.x, geometry.boundsPoints.maxX)
        XCTAssertLessThan(p.y, geometry.boundsPoints.maxY)
    }

    func testCenterMapsToWindowCenter() throws {
        let p = try geometry.screenPoint(fromPixelX: 410, pixelY: 740)
        XCTAssertEqual(p, CGPoint(x: 305, y: 420))
    }

    func testOutOfBoundsThrows() {
        XCTAssertThrowsError(try geometry.screenPoint(fromPixelX: 821, pixelY: 10))
        XCTAssertThrowsError(try geometry.screenPoint(fromPixelX: -1, pixelY: 10))
        XCTAssertThrowsError(try geometry.screenPoint(fromPixelX: 10, pixelY: 1481))
    }

    func testRoundTrip() throws {
        let screen = try geometry.screenPoint(fromPixelX: 123, pixelY: 456)
        let pixel = geometry.pixel(fromScreenPoint: screen)
        XCTAssertEqual(pixel.x, 123, accuracy: 0.001)
        XCTAssertEqual(pixel.y, 456, accuracy: 0.001)
    }

    func testNonUniformScale() throws {
        // Downscaled screenshot: 410x740 points captured into 205x370 pixels (0.5x).
        let g = WindowGeometry(
            windowID: 1,
            boundsPoints: CGRect(x: 0, y: 0, width: 410, height: 740),
            imagePixelSize: CGSize(width: 205, height: 370)
        )
        // Far edge clamps 0.5px inward: (204.5, 369.5) at 0.5 px/pt = (409, 739).
        let p = try g.screenPoint(fromPixelX: 205, pixelY: 370)
        XCTAssertEqual(p, CGPoint(x: 409, y: 739))
        // Interior points are unaffected by the clamp.
        let mid = try g.screenPoint(fromPixelX: 102.5, pixelY: 185)
        XCTAssertEqual(mid, CGPoint(x: 205, y: 370))
    }
}
