import XCTest
@testable import MirrorCore

/// `withOneRetry` semantics (capture-retry fix, 2026-08-12 shakedown F5) and
/// the honesty of the capture failure remediation text.
final class RetryTests: XCTestCase {
    private struct TestFailure: Error, Equatable { let id: Int }

    /// Thread-safe call recorder (the closure is async).
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [Int] = []
        func record(_ attempt: Int) {
            lock.lock(); defer { lock.unlock() }
            attempts.append(attempt)
        }
        var value: [Int] {
            lock.lock(); defer { lock.unlock() }
            return attempts
        }
    }

    func testFirstSuccessDoesNotRetry() async throws {
        let calls = Calls()
        let value = try await withOneRetry(delayNs: 1) { attempt -> Int in
            calls.record(attempt)
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls.value, [0])
    }

    func testFailureRetriesExactlyOnceThenSucceeds() async throws {
        let calls = Calls()
        let value = try await withOneRetry(delayNs: 1) { attempt -> Int in
            calls.record(attempt)
            if attempt == 0 { throw TestFailure(id: 0) }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(calls.value, [0, 1])
    }

    func testSecondFailurePropagatesSecondError() async {
        let calls = Calls()
        do {
            _ = try await withOneRetry(delayNs: 1) { attempt -> Int in
                calls.record(attempt)
                throw TestFailure(id: attempt)
            }
            XCTFail("expected the retry to rethrow")
        } catch let failure as TestFailure {
            XCTAssertEqual(failure.id, 1, "the SECOND attempt's error must propagate")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(calls.value, [0, 1])
    }

    func testCaptureRemediationBlamesPermissionOnlyWhenMissing() {
        let granted = MirrorCapture.captureRemediation(permissionGranted: true)
        XCTAssertTrue(granted.contains("transient"),
                      "with the permission granted, the remediation must point at transient causes")
        XCTAssertFalse(granted.contains("Check Screen Recording permission"),
                       "must not send the caller to System Settings when the permission is granted")

        let denied = MirrorCapture.captureRemediation(permissionGranted: false)
        XCTAssertTrue(denied.contains("Check Screen Recording permission"))
    }
}
