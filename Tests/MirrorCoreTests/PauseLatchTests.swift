import XCTest
@testable import MirrorCore

/// The kill switch. A paused session is resumed by software only when its
/// overlay exposes a button labeled Resume. "iPhone in Use" and an overlay
/// with no labeled button are never clicked, and once such a pause is seen
/// every input path is refused until a person resumes the session (the
/// session observes `.connected` again) or the server restarts.
final class PauseLatchTests: XCTestCase {
    /// A scripted bridge: the state and overlay are whatever the test sets,
    /// presses and clicks are counted, and a press can flip the state to
    /// connected the way a real Resume click does.
    final class Script: @unchecked Sendable {
        var state: MirroringState
        var overlay: MirrorWindowBridge.PauseOverlay
        var connectsOnPress = false
        private(set) var presses = 0
        private(set) var clicks = 0

        init(state: MirroringState, overlay: MirrorWindowBridge.PauseOverlay) {
            self.state = state
            self.overlay = overlay
        }

        var probe: MirrorSession.SessionProbe {
            MirrorSession.SessionProbe(
                state: { self.state },
                overlay: { self.overlay },
                pressResume: {
                    self.presses += 1
                    if self.connectsOnPress { self.state = .connected }
                    return true
                },
                clickResume: {
                    self.clicks += 1
                    return false
                })
        }
    }

    private func assertPausedRefusal(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected the call to be refused while paused")
        } catch {
            XCTAssertEqual(error as? MirrorError, MirrorError.sessionPaused(), "\(error)")
        }
    }

    func testInUseOverlayIsNeverResumedAndLatches() async {
        let script = Script(state: .paused, overlay: .inUse)
        let session = MirrorSession(probe: script.probe)
        await assertPausedRefusal { try await session.tap(x: 10, y: 10) }
        XCTAssertEqual(script.presses, 0)
        XCTAssertEqual(script.clicks, 0)
        let latched = await session.pauseLatched
        XCTAssertTrue(latched)
    }

    func testUnlabeledOverlayLatches() async {
        let script = Script(state: .paused, overlay: .unknown)
        let session = MirrorSession(probe: script.probe)
        await assertPausedRefusal { try await session.tap(x: 10, y: 10) }
        XCTAssertEqual(script.presses, 0)
        XCTAssertEqual(script.clicks, 0)
        let latched = await session.pauseLatched
        XCTAssertTrue(latched)
    }

    /// The readiness gate is the same code for reads and input; the read
    /// variant is used here because the input variant goes on to query the
    /// real Accessibility grant and activate the real app.
    func testLabeledResumeIsPressedOnceAndSucceeds() async {
        let script = Script(state: .paused, overlay: .resumeButton)
        script.connectsOnPress = true
        let session = MirrorSession(probe: script.probe)
        let error = await session.ensureReady(forInput: false)
        XCTAssertNil(error, "\(error!)")
        XCTAssertEqual(script.presses, 1)
        XCTAssertEqual(script.clicks, 0)
        let latched = await session.pauseLatched
        XCTAssertFalse(latched)
    }

    func testLabeledResumeThatFailsLatches() async {
        let script = Script(state: .paused, overlay: .resumeButton)
        let session = MirrorSession(probe: script.probe)
        await assertPausedRefusal { try await session.tap(x: 10, y: 10) }
        XCTAssertEqual(script.presses, 1)
        XCTAssertEqual(script.clicks, 1)
        var latched = await session.pauseLatched
        XCTAssertTrue(latched)
        // Latched: the second attempt presses nothing, even with the button still there.
        await assertPausedRefusal { try await session.tap(x: 10, y: 10) }
        XCTAssertEqual(script.presses, 1)
        XCTAssertEqual(script.clicks, 1)
        latched = await session.pauseLatched
        XCTAssertTrue(latched)
    }

    func testReadPathProceedsWhilePaused() async {
        let script = Script(state: .paused, overlay: .inUse)
        let session = MirrorSession(probe: script.probe)
        await assertPausedRefusal { try await session.tap(x: 10, y: 10) }
        let error = await session.ensureReady(forInput: false)
        XCTAssertNil(error, "\(error!)")
        let latched = await session.pauseLatched
        XCTAssertTrue(latched, "a read must not clear the latch")
    }

    func testLatchClearsWhenConnectedIsObserved() async {
        let script = Script(state: .paused, overlay: .inUse)
        let session = MirrorSession(probe: script.probe)
        _ = await session.status()
        var latched = await session.pauseLatched
        XCTAssertTrue(latched)
        script.state = .connected
        _ = await session.status()
        latched = await session.pauseLatched
        XCTAssertFalse(latched)
    }

    /// The relaunch paths are the one way software could reconnect a session
    /// a person paused, and the wrappers for notification_click and batch
    /// call the same gate.
    func testLaunchRestartNotificationBatchRefuseWhilePaused() async {
        let script = Script(state: .paused, overlay: .inUse)
        let session = MirrorSession(probe: script.probe)
        await assertPausedRefusal { _ = try await session.launchMirroring() }
        await assertPausedRefusal { _ = try await session.restartMirroring() }
        await assertPausedRefusal { try await session.requireSessionNotPaused() }
        XCTAssertEqual(script.presses, 0)
        XCTAssertEqual(script.clicks, 0)
    }
}
