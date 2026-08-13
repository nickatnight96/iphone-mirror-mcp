import CoreGraphics
import XCTest
@testable import MirrorCore

/// Tests that need the real machine: the iPhone Mirroring app, TCC
/// permissions, or Xcode CLIs. Skipped unless MIRROR_MCP_LIVE=1
/// (scripts/run_tests.sh forwards it).
final class LiveIntegrationTests: XCTestCase {
    func requireLive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MIRROR_MCP_LIVE"] == "1",
            "set MIRROR_MCP_LIVE=1 to run live integration tests")
    }

    func testFindsMirroringWindow() throws {
        try requireLive()
        let bridge = MirrorWindowBridge()
        try XCTSkipIf(bridge.findProcess() == nil, "iPhone Mirroring is not running")
        let info = try XCTUnwrap(bridge.windowInfo(), "window not found")
        XCTAssertGreaterThan(info.bounds.width, 100)
        XCTAssertGreaterThan(info.bounds.height, 100)
        XCTAssertNotEqual(bridge.state(), .notRunning)
    }

    func testScreenshotCapturesPixels() async throws {
        try requireLive()
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Screen Recording permission not granted")
        let bridge = MirrorWindowBridge()
        let info = try XCTUnwrap(bridge.windowInfo(), "window not found")
        let capture = try await MirrorCapture.capture(windowInfo: info)
        XCTAssertGreaterThan(capture.image.width, 100)
        let png = try ImageUtil.pngData(from: capture.image)
        XCTAssertGreaterThan(png.count, 10_000, "suspiciously small screenshot")
        // OCR should run without throwing on a real frame.
        _ = try MirrorOCR.recognizeText(in: capture.image, fast: true)
    }

    func testDevicectlAndSimctlListing() async throws {
        try requireLive()
        _ = try await XcodeTools.physicalDevices()
        let sims = try await XcodeTools.simulators()
        XCTAssertFalse(sims.devices.isEmpty)
    }

    /// F1 (2026-08-12 shakedown): activation must be VERIFIED to have taken
    /// focus — iPhone Mirroring silently drops input while another app is
    /// frontmost, and `NSRunningApplication.isActive` lies in a process that
    /// never pumps its run loop. This is the seam nothing previously executed.
    func testActivateBringsMirroringFrontmost() throws {
        try requireLive()
        try XCTSkipUnless(PermissionStatus.current().accessibility, "Accessibility permission not granted")
        let bridge = MirrorWindowBridge()
        guard let app = bridge.findProcess() else { throw XCTSkip("iPhone Mirroring is not running") }
        XCTAssertTrue(bridge.activate(), "activate() reported it could not take focus")
        XCTAssertEqual(bridge.frontmostPID(), app.processIdentifier,
                       "iPhone Mirroring is not frontmost after activate() — input would be silently dropped")
    }

    /// F2 (2026-08-12 shakedown): scroll gestures route by the REAL cursor
    /// position, so placeCursor must verifiably move it — not just post a
    /// warp and hope. Restores the user's cursor afterwards.
    func testPlaceCursorVerifiablyMovesTheCursor() throws {
        try requireLive()
        try XCTSkipUnless(PermissionStatus.current().accessibility, "Accessibility permission not granted")
        let original = CGEvent(source: nil)?.location
        defer { if let original { CGWarpMouseCursorPosition(original) } }

        let target = CGPoint(x: 400, y: 300)
        try MirrorInput.placeCursor(at: target)
        let landed = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertTrue(
            MirrorInput.cursorIsPlaced(current: landed, target: target,
                                       tolerance: MirrorInput.cursorPlacementTolerance),
            "cursor at \(landed), expected within \(MirrorInput.cursorPlacementTolerance) of \(target)")
    }
}
