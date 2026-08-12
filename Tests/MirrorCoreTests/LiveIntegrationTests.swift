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
}
