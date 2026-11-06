import XCTest
@testable import MirrorCore

/// The kill switch. A paused session is resumed by software only when its
/// overlay exposes a button labeled Resume. "iPhone in Use" and an overlay
/// with no labeled button are never clicked, and once such a pause is seen
/// every input path is refused until a person resumes the session (the
/// session observes `.connected` again) or the server restarts.
final class PauseLatchTests: XCTestCase {
    /// A scripted bridge: the state and overlay are whatever the test sets,
    /// presses and clicks are counted, a press can flip the state to
    /// connected the way a real Resume click does, and `nextStates` feeds
    /// one state per read after the current one (a phone picked up between
    /// two reads). Accessibility and activation answer true so the input
    /// gate reaches its last state read.
    final class Script: @unchecked Sendable {
        var state: MirroringState
        var nextStates: [MirroringState] = []
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
                state: {
                    let current = self.state
                    if !self.nextStates.isEmpty { self.state = self.nextStates.removeFirst() }
                    return current
                },
                overlay: { self.overlay },
                pressResume: {
                    self.presses += 1
                    if self.connectsOnPress { self.state = .connected }
                    return true
                },
                clickResume: {
                    self.clicks += 1
                    return false
                },
                accessibilityGranted: { true },
                activate: { true })
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

    /// The gate is called directly, not through tap: a tap that passes the
    /// gate goes on to post real input to whatever window is on screen.
    func testLabeledResumeIsPressedOnceAndSucceeds() async {
        let script = Script(state: .paused, overlay: .resumeButton)
        script.connectsOnPress = true
        let session = MirrorSession(probe: script.probe)
        let error = await session.ensureReady(forInput: true)
        XCTAssertNil(error, "\(error!)")
        XCTAssertEqual(script.presses, 1)
        XCTAssertEqual(script.clicks, 0)
        let latched = await session.pauseLatched
        XCTAssertFalse(latched)
    }

    /// A read never resumes: only an input call presses Resume, so a
    /// screenshot of an idle pause presses and clicks nothing, and the next
    /// input call can still resume it.
    func testReadNeverPressesResume() async {
        let script = Script(state: .paused, overlay: .resumeButton)
        let session = MirrorSession(probe: script.probe)
        let error = await session.ensureReady(forInput: false)
        XCTAssertNil(error, "\(error!)")
        XCTAssertEqual(script.presses, 0)
        XCTAssertEqual(script.clicks, 0)
        let latched = await session.pauseLatched
        XCTAssertFalse(latched, "a read must not latch an idle pause it did not try to resume")
    }

    /// A person can pick up the phone after the first state read. The gate
    /// reads the state once more after the Accessibility and activation
    /// checks, so input never goes out to a session that paused in between.
    func testPauseBetweenGateChecksIsRefused() async {
        let script = Script(state: .connected, overlay: .inUse)
        script.nextStates = [.paused]
        let session = MirrorSession(probe: script.probe)
        let error = await session.ensureReady(forInput: true)
        XCTAssertEqual(error, MirrorError.sessionPaused())
        let latched = await session.pauseLatched
        XCTAssertTrue(latched)
        XCTAssertEqual(script.presses, 0)
        XCTAssertEqual(script.clicks, 0)
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

    /// The multi-step flows stop at their first step while latched.
    func testLaunchAppAndOpenURLRefuseWhileLatched() async {
        let script = Script(state: .paused, overlay: .inUse)
        let session = MirrorSession(probe: script.probe)
        await assertPausedRefusal { try await session.requireSessionNotPaused() }
        let latched = await session.pauseLatched
        XCTAssertTrue(latched)
        await assertPausedRefusal { try await session.launchApp(named: "Settings") }
        await assertPausedRefusal { try await session.openURL("https://example.com") }
        XCTAssertEqual(script.presses, 0)
        XCTAssertEqual(script.clicks, 0)
    }

    /// Only `.connected` clears the latch. An app that quits or a window
    /// that closes while latched does not.
    func testLatchSurvivesNotRunningAndNoWindow() async {
        let script = Script(state: .paused, overlay: .inUse)
        let session = MirrorSession(probe: script.probe)
        _ = await session.status()
        for state in [MirroringState.notRunning, .noWindow] {
            script.state = state
            _ = await session.status()
            let latched = await session.pauseLatched
            XCTAssertTrue(latched, "\(state) must not clear the latch")
        }
        await assertPausedRefusal { try await session.requireSessionNotPaused() }
    }

    /// A generic "ok" must never count as Resume, and no label may be both
    /// a Resume label and an "iPhone in Use" label.
    func testResumeTitlesExcludeOkAndInUseLabels() {
        XCTAssertFalse(MirrorWindowBridge.resumeButtonTitles.contains("ok"))
        XCTAssertTrue(MirrorWindowBridge.resumeButtonTitles.isDisjoint(with: MirrorWindowBridge.inUseButtonTitles))
    }
}
