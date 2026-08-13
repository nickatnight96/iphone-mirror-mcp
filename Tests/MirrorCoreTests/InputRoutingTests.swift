import CoreGraphics
import XCTest
@testable import MirrorCore

/// Pure geometry behind the input-routing fixes from the 2026-08-12 shakedown:
/// cursor-placement verification (F2) and the pause-overlay center click (F3).
final class InputRoutingTests: XCTestCase {
    func testCursorIsPlacedWithinTolerance() {
        XCTAssertTrue(MirrorInput.cursorIsPlaced(
            current: CGPoint(x: 100, y: 100), target: CGPoint(x: 102, y: 98), tolerance: 3))
    }

    func testCursorIsPlacedAcceptsExactBoundary() {
        XCTAssertTrue(MirrorInput.cursorIsPlaced(
            current: CGPoint(x: 103, y: 97), target: CGPoint(x: 100, y: 100), tolerance: 3))
    }

    func testCursorIsPlacedRejectsEitherAxisOutOfTolerance() {
        XCTAssertFalse(MirrorInput.cursorIsPlaced(
            current: CGPoint(x: 104, y: 100), target: CGPoint(x: 100, y: 100), tolerance: 3))
        XCTAssertFalse(MirrorInput.cursorIsPlaced(
            current: CGPoint(x: 100, y: 95), target: CGPoint(x: 100, y: 100), tolerance: 3))
    }

    /// The exact geometry that resumed sessions live: window at (605, 121)
    /// 348×766 → Resume at the center (779, 504), and the "iPhone in Use"
    /// Connect button at ~65% height (779, ~619).
    func testPauseOverlayClickPointsCoverBothOverlayVariants() {
        let points = MirrorSession.pauseOverlayClickPoints(
            for: CGRect(x: 605, y: 121, width: 348, height: 766))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, 779, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 504, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 779, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 619, accuracy: 1)
        XCTAssertTrue(MirrorSession.pauseOverlayClickPoints(for: nil).isEmpty)
    }

    /// The System Events click script must carry integer screen coordinates.
    func testSystemEventsClickSourceFormatsIntegerCoordinates() {
        XCTAssertEqual(
            MirrorWindowBridge.systemEventsClickSource(at: CGPoint(x: 892.4, y: 335.6)),
            "tell application \"System Events\" to click at {892, 336}")
    }

    /// F6 (2026-08-12): iPhone Mirroring owns menu-bar-sized phantom windows
    /// (four at 1512×33 and one 64×64, observed live). A width-only filter
    /// matched one and captured a blank 3024×66 strip — the size check must
    /// test BOTH dimensions, everywhere a window is looked up.
    func testUsableWindowSizeRejectsPhantomWindows() {
        XCTAssertFalse(MirrorWindowBridge.isUsableWindowSize(width: 1512, height: 33))
        XCTAssertFalse(MirrorWindowBridge.isUsableWindowSize(width: 64, height: 64))
        XCTAssertFalse(MirrorWindowBridge.isUsableWindowSize(width: 90, height: 900))
        XCTAssertTrue(MirrorWindowBridge.isUsableWindowSize(width: 348, height: 766))
        XCTAssertTrue(MirrorWindowBridge.isUsableWindowSize(width: 640, height: 662))
    }
}
