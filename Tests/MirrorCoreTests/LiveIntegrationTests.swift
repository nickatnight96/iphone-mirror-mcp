import CoreGraphics
import ImageIO
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

    /// paste_text's clipboard save/restore contract: whatever the user had
    /// on the pasteboard must survive a set + restore round-trip. Live-gated
    /// because it touches the real user pasteboard.
    func testPasteboardSnapshotRestoreRoundTrip() throws {
        try requireLive()
        let original = MacPasteboard.snapshot()
        defer { MacPasteboard.restore(original) }

        let sentinel = "iphone-mirror-mcp-roundtrip-\(UUID().uuidString)"
        MacPasteboard.setString(sentinel)
        XCTAssertEqual(MacPasteboard.string(), sentinel)

        MacPasteboard.restore(original)
        // Restoring the original must remove the sentinel again.
        XCTAssertNotEqual(MacPasteboard.string(), sentinel)
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

    // MARK: - Swipe gesture (exercises SwipePlan end to end)

    /// Skips unless a live, ACTIVE mirroring session is available. A paused
    /// session captures a static overlay, so a swipe would "fail" for reasons
    /// that have nothing to do with the gesture.
    private func requireActiveSession() async throws -> MirrorSession {
        try requireLive()
        try XCTSkipUnless(PermissionStatus.current().accessibility, "Accessibility permission not granted")
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Screen Recording permission not granted")
        let session = MirrorSession()
        let status = await session.status()
        try XCTSkipUnless(status.state == .connected,
                          "mirroring session is \(status.state) — lock the iPhone and click Resume")
        return session
    }

    /// Screenshots come back as PNG bytes; decode so frames can be compared
    /// perceptually. Byte equality would be too strict — a status-bar clock
    /// tick alone would register as "the screen scrolled".
    private func decode(_ shot: MirrorSession.Screenshot) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(shot.pngData as CFData, nil),
                                   "screenshot PNG could not be decoded")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The planner's math is unit-tested, but nothing there proves the phone
    /// actually scrolls: the deltas must survive quantization, the phase
    /// script, CGEvent posting, and the mirroring app's gesture recognizer.
    /// Settings is used because it is present on every iPhone and its root
    /// list is always taller than the screen.
    func testFlickScrollsRealContent() async throws {
        let session = try await requireActiveSession()
        try await session.launchApp(named: "Settings")
        _ = try? await session.waitForText("Settings", timeoutSeconds: 8, exact: false)

        let before = try decode(try await session.screenshot())
        let width = Double(before.width)
        let height = Double(before.height)

        // Fast upward flick through the middle of the list.
        try await session.swipe(fromX: width / 2, fromY: height * 0.75,
                                toX: width / 2, toY: height * 0.25, durationMs: 180)
        try await Task.sleep(for: .milliseconds(1200))  // let inertia settle

        let after = try decode(try await session.screenshot())
        let difference = ImageUtil.meanAbsDifference(before, after)
        XCTAssertGreaterThan(difference, 0.01,
                             "a flick left the screen unchanged — the gesture never reached the phone")
    }

    /// Slow swipes take the no-momentum path through the planner, which is a
    /// separate branch from the flick above.
    func testSlowDragScrollsRealContent() async throws {
        let session = try await requireActiveSession()
        try await session.launchApp(named: "Settings")
        _ = try? await session.waitForText("Settings", timeoutSeconds: 8, exact: false)

        let before = try decode(try await session.screenshot())
        let width = Double(before.width)
        let height = Double(before.height)

        // 0.35 of the screen over 1.5s stays under the flick threshold.
        try await session.swipe(fromX: width / 2, fromY: height * 0.7,
                                toX: width / 2, toY: height * 0.35, durationMs: 1500)
        try await Task.sleep(for: .milliseconds(600))

        let after = try decode(try await session.screenshot())
        let difference = ImageUtil.meanAbsDifference(before, after)
        XCTAssertGreaterThan(difference, 0.01,
                             "a slow drag left the screen unchanged")
    }

    /// A swipe must leave the session usable. The phase script exists because
    /// a truncated gesture wedges SpringBoard: video keeps streaming but all
    /// further input is dropped. Posting a gesture and then asserting a
    /// SUBSEQUENT gesture still registers is the only way to catch that.
    func testSessionStillAcceptsInputAfterASwipe() async throws {
        let session = try await requireActiveSession()
        try await session.launchApp(named: "Settings")
        _ = try? await session.waitForText("Settings", timeoutSeconds: 8, exact: false)

        let shot = try decode(try await session.screenshot())
        let width = Double(shot.width)
        let height = Double(shot.height)

        try await session.swipe(fromX: width / 2, fromY: height * 0.75,
                                toX: width / 2, toY: height * 0.25, durationMs: 150)
        try await Task.sleep(for: .milliseconds(1200))

        // If SpringBoard wedged, this second gesture changes nothing.
        let before = try decode(try await session.screenshot())
        try await session.swipe(fromX: width / 2, fromY: height * 0.3,
                                toX: width / 2, toY: height * 0.7, durationMs: 400)
        try await Task.sleep(for: .milliseconds(800))
        let after = try decode(try await session.screenshot())

        let difference = ImageUtil.meanAbsDifference(before, after)
        XCTAssertGreaterThan(difference, 0.01,
                             "input stopped registering after a swipe — the session may be wedged")
    }
}
