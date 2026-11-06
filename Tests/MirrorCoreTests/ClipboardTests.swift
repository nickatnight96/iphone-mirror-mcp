import XCTest
@testable import MirrorCore

/// The bridged copy lands on the Mac pasteboard asynchronously. read_clipboard
/// must wait for the pasteboard change count to move instead of sleeping a
/// fixed time and returning whatever the Mac clipboard held before.
final class ClipboardTests: XCTestCase {
    func testWaitForChangeReturnsWhenChangeCountMoves() {
        var calls = 0
        let moved = MacPasteboard.waitForChange(since: 7, timeout: 5, pollInterval: 0.001) {
            calls += 1
            return calls < 3 ? 7 : 8
        }
        XCTAssertTrue(moved)
        XCTAssertEqual(calls, 3)
    }

    func testWaitForChangeTimesOutWhenUnchanged() {
        let start = Date()
        let moved = MacPasteboard.waitForChange(since: 7, timeout: 0.1, pollInterval: 0.01) { 7 }
        XCTAssertFalse(moved)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
    }
}
