import XCTest
@testable import MirrorCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutAndExitCode() async throws {
        let result = try await ProcessRunner.run("/bin/echo", ["hello", "world"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testCapturesStderrAndNonZeroExit() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("oops"))
    }

    func testTimeoutKillsProcess() async throws {
        let start = Date()
        let result = try await ProcessRunner.run("/bin/sleep", ["30"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testMissingExecutableThrowsMirrorError() async {
        do {
            _ = try await ProcessRunner.run("/no/such/binary", [])
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is MirrorError)
        }
    }

    func testTruncationKeepsHeadAndTail() {
        let head = String(repeating: "A", count: 500)
        let tail = String(repeating: "Z", count: 1500)
        let data = Data((head + tail).utf8)
        let out = ProcessRunner.truncated(data, maxBytes: 1000)
        XCTAssertTrue(out.hasPrefix("AAAA"))
        XCTAssertTrue(out.hasSuffix("ZZZZ"))
        XCTAssertTrue(out.contains("bytes elided"))
        // Roughly respects the cap (plus the elision marker).
        XCTAssertLessThan(out.count, 1100)
    }

    func testNoTruncationUnderCap() {
        let out = ProcessRunner.truncated(Data("short".utf8), maxBytes: 1000)
        XCTAssertEqual(out, "short")
    }

    func testCurrentDirectoryIsRespected() async throws {
        let result = try await ProcessRunner.run("/bin/pwd", [], currentDirectory: "/private/tmp")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "/private/tmp")
    }
}
