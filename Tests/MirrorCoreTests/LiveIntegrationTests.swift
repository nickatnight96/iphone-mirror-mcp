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

    /// Thresholds calibrated against measurements on a live session
    /// (2026-08-13, Settings on iPhone, window 348x766pt):
    ///
    ///     settled idle   pixelDiff 0.000   row churn 0-3
    ///     real flick     pixelDiff 0.043   5 rows out + 6 in  = 11
    ///     real drag      pixelDiff 0.060   8 rows out + 1 in  =  9
    ///
    /// Pixel difference alone is a weak signal: before the screen settles it
    /// reads 0.03-0.06 from animation alone, the same magnitude as a real
    /// scroll. The gate is therefore the OCR row set — a scroll changes WHICH
    /// rows are visible, and video-stream noise cannot fake that.
    ///
    /// The two row thresholds are deliberately separated rather than sharing
    /// one constant. OCR is not perfectly repeatable frame to frame (an idle
    /// screen churns by up to 3 rows), so the idle ceiling and the scroll
    /// floor need a gap between them; 9 is the smallest real scroll observed.
    private static let scrollPixelThreshold = 0.01
    private static let idleRowChurnLimit = 4
    private static let scrollRowChangeThreshold = 6

    /// The set of text the phone is currently showing. Short fragments are
    /// dropped because single characters are where OCR is least stable.
    private func visibleRows(_ session: MirrorSession) async throws -> Set<String> {
        Set(try await session.readScreen()
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 })
    }

    /// Drives the list back to the top so each test starts from the same
    /// place. Without this the tests are order-dependent: each one scrolls
    /// Settings further down, and once the list bottoms out a further
    /// downward scroll correctly does nothing — so a later test fails for a
    /// reason that has nothing to do with the gesture engine.
    private func scrollToTop(_ session: MirrorSession) async throws {
        let shot = try decode(try await session.screenshot())
        let width = Double(shot.width), height = Double(shot.height)
        var previous = try await visibleRows(session)
        for _ in 1...8 {
            // Finger travels DOWN, so the content travels down: scroll up.
            try await session.swipe(fromX: width / 2, fromY: height * 0.3,
                                    toX: width / 2, toY: height * 0.8, durationMs: 900)
            try await Task.sleep(for: .milliseconds(300))
            let current = try await visibleRows(session)
            if current == previous { return }   // reached the top
            previous = current
        }
    }

    /// Settles the screen, then confirms it is genuinely still. Asserting that
    /// a swipe changed the screen proves nothing unless the screen would
    /// otherwise have stayed put — an app still animating in changes by as
    /// much as a real scroll, which is exactly how this test passed for the
    /// wrong reason before the control was added.
    private func settleAndConfirmStill(_ session: MirrorSession) async throws {
        _ = try? await session.waitForScreenChange(mode: "stable", timeoutSeconds: 10, threshold: 0.02)
        let first = try decode(try await session.screenshot())
        let firstRows = try await visibleRows(session)
        try await Task.sleep(for: .milliseconds(600))
        let second = try decode(try await session.screenshot())
        let secondRows = try await visibleRows(session)

        let drift = ImageUtil.meanAbsDifference(first, second)
        XCTAssertLessThan(drift, Self.scrollPixelThreshold,
                          "the idle screen drifts by \(drift); a scroll cannot be distinguished from it")
        let churn = firstRows.symmetricDifference(secondRows).count
        XCTAssertLessThan(churn, Self.idleRowChurnLimit,
                          "the idle row set churns by \(churn); OCR is too unstable right now "
                          + "to tell a real scroll from recognition noise")
    }

    /// Performs a gesture and measures whether it scrolled, retrying ONCE on
    /// a null result. A single retry is safe here: the failures these tests
    /// exist to catch — a wedged session, a planner that never moves content —
    /// are persistent and fail both attempts. What the retry absorbs is the
    /// documented transient: the mirroring app discards input around focus
    /// changes, so back-to-back suite runs occasionally drop one gesture.
    private func measureScroll(
        _ session: MirrorSession,
        gesture: (Double, Double) async throws -> Void
    ) async throws -> (pixelDifference: Double, before: Set<String>, after: Set<String>) {
        var result = (pixelDifference: 0.0, before: Set<String>(), after: Set<String>())
        for attempt in 1...2 {
            let before = try decode(try await session.screenshot())
            let beforeRows = try await visibleRows(session)
            try await gesture(Double(before.width), Double(before.height))
            try await Task.sleep(for: .milliseconds(2000))
            let after = try decode(try await session.screenshot())
            let afterRows = try await visibleRows(session)
            result = (ImageUtil.meanAbsDifference(before, after), beforeRows, afterRows)
            let moved = result.before.subtracting(result.after).count
                      + result.after.subtracting(result.before).count
            if result.pixelDifference > Self.scrollPixelThreshold,
               moved >= Self.scrollRowChangeThreshold { return result }
            if attempt == 1 {
                print("live-test note: gesture did not register, retrying once "
                      + "(pixelDiff=\(result.pixelDifference), rows moved=\(moved))")
            }
        }
        return result
    }

    /// Asserts the phone scrolled: the frame changed AND the visible rows did.
    private func assertScrolled(
        pixelDifference: Double, before: Set<String>, after: Set<String>,
        _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let departed = before.subtracting(after).count
        let arrived = after.subtracting(before).count
        XCTAssertGreaterThan(pixelDifference, Self.scrollPixelThreshold,
                             "\(what): the frame did not change — the gesture never reached the phone",
                             file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            departed + arrived, Self.scrollRowChangeThreshold,
            "\(what): the frame changed but the visible rows did not "
            + "(\(departed) out, \(arrived) in) — that is not a scroll",
            file: file, line: line)
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
        try await scrollToTop(session)
        try await settleAndConfirmStill(session)

        // Fast upward flick through the middle of the list.
        let result = try await measureScroll(session) { width, height in
            try await session.swipe(fromX: width / 2, fromY: height * 0.75,
                                    toX: width / 2, toY: height * 0.25, durationMs: 180)
        }
        assertScrolled(pixelDifference: result.pixelDifference,
                       before: result.before, after: result.after, "flick")
    }

    /// Slow swipes take the no-momentum path through the planner, which is a
    /// separate branch from the flick above.
    func testSlowDragScrollsRealContent() async throws {
        let session = try await requireActiveSession()
        try await session.launchApp(named: "Settings")
        _ = try? await session.waitForText("Settings", timeoutSeconds: 8, exact: false)
        try await scrollToTop(session)
        try await settleAndConfirmStill(session)

        // 0.35 of the screen over 1.5s stays under the flick threshold.
        let result = try await measureScroll(session) { width, height in
            try await session.swipe(fromX: width / 2, fromY: height * 0.7,
                                    toX: width / 2, toY: height * 0.35, durationMs: 1500)
        }
        assertScrolled(pixelDifference: result.pixelDifference,
                       before: result.before, after: result.after, "slow drag")
    }

    /// A swipe must leave the session usable. The phase script exists because
    /// a truncated gesture wedges SpringBoard: video keeps streaming but all
    /// further input is dropped. Posting a gesture and then asserting a
    /// SUBSEQUENT gesture still registers is the only way to catch that.
    func testSessionStillAcceptsInputAfterASwipe() async throws {
        let session = try await requireActiveSession()
        try await session.launchApp(named: "Settings")
        _ = try? await session.waitForText("Settings", timeoutSeconds: 8, exact: false)
        try await scrollToTop(session)
        try await settleAndConfirmStill(session)

        let shot = try decode(try await session.screenshot())
        let width = Double(shot.width)
        let height = Double(shot.height)

        try await session.swipe(fromX: width / 2, fromY: height * 0.75,
                                toX: width / 2, toY: height * 0.25, durationMs: 150)
        try await Task.sleep(for: .milliseconds(1200))

        // If SpringBoard wedged, this second gesture changes nothing.
        let result = try await measureScroll(session) { width, height in
            try await session.swipe(fromX: width / 2, fromY: height * 0.3,
                                    toX: width / 2, toY: height * 0.7, durationMs: 400)
        }
        assertScrolled(pixelDifference: result.pixelDifference,
                       before: result.before, after: result.after,
                       "second gesture after a swipe (the session may be wedged)")
    }
}
