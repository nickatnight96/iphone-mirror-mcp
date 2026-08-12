import XCTest
@testable import MirrorCore

final class XcodebuildOutputTests: XCTestCase {
    func testBuildFailureWithDuplicateErrors() {
        let log = """
        Building for debugging...
        /app/Sources/Foo.swift:10:5: error: cannot find 'bar' in scope
        /app/Sources/Foo.swift:10:5: error: cannot find 'bar' in scope
        /app/Sources/Baz.swift:2:1: warning: unused variable 'x'
        ** BUILD FAILED **
        """
        let summary = XcodebuildOutputParser.parse(log)
        XCTAssertEqual(summary.outcome, .buildFailed)
        XCTAssertEqual(summary.errors.count, 1)
        XCTAssertTrue(summary.errors[0].contains("cannot find 'bar' in scope"))
        XCTAssertEqual(summary.warnings.count, 1)
        XCTAssertNil(summary.testCounts)
    }

    func testBuildSuccess() {
        let summary = XcodebuildOutputParser.parse("stuff\n** BUILD SUCCEEDED **\n")
        XCTAssertEqual(summary.outcome, .buildSucceeded)
        XCTAssertTrue(summary.errors.isEmpty)
    }

    func testXCTestCountsTakeLastAggregate() {
        let log = """
        Test Suite 'FooTests' passed at 2026-08-12 10:00:00.000.
             Executed 4 tests, with 0 failures (0 unexpected) in 0.1 (0.2) seconds
        Test Suite 'All tests' failed at 2026-08-12 10:00:01.000.
             Executed 12 tests, with 1 failure (0 unexpected) in 1.0 (1.1) seconds
        ** TEST FAILED **
        """
        let summary = XcodebuildOutputParser.parse(log)
        XCTAssertEqual(summary.outcome, .testFailed)
        XCTAssertEqual(summary.testCounts, .init(executed: 12, failures: 1))
    }

    func testSwiftTestingSummary() {
        let log = """
        ✔ Test run with 5 tests passed after 0.5 seconds.
        ** TEST SUCCEEDED **
        """
        let summary = XcodebuildOutputParser.parse(log)
        XCTAssertEqual(summary.outcome, .testSucceeded)
        XCTAssertEqual(summary.testCounts, .init(executed: 5, failures: 0))
    }

    func testSwiftTestingFailureCountsFailedCases() {
        let log = """
        ✘ Test "adds numbers" failed after 0.1 seconds with 1 issue.
        ✘ Test "parses input" failed after 0.2 seconds with 2 issues.
        ✘ Test run with 5 tests failed after 0.5 seconds with 3 issues.
        ** TEST FAILED **
        """
        let summary = XcodebuildOutputParser.parse(log)
        XCTAssertEqual(summary.outcome, .testFailed)
        XCTAssertEqual(summary.testCounts?.executed, 5)
        // At least the individually-failed cases are counted (never zero).
        XCTAssertGreaterThanOrEqual(summary.testCounts?.failures ?? 0, 2)
    }

    func testXcodebuildToolError() {
        let log = "xcodebuild: error: The project named \"Nope\" does not exist.\n"
        let summary = XcodebuildOutputParser.parse(log)
        XCTAssertEqual(summary.outcome, .unknown)
        XCTAssertEqual(summary.errors.count, 1)
    }

    func testFailedRunWithNoParsedErrorsAttachesRawTail() {
        // Errors elided by log truncation must not leave the caller actionless.
        let outcome = XcodeTools.BuildOutcome(
            summary: XcodebuildSummary(outcome: .buildFailed, errors: [], warnings: [], testCounts: nil),
            exitCode: 65,
            timedOut: false,
            rawTail: "…The following build commands failed:\n  SwiftCompile Foo.swift"
        )
        XCTAssertTrue(outcome.description.contains("output tail"))
        XCTAssertTrue(outcome.description.contains("SwiftCompile Foo.swift"))

        // A successful run stays clean.
        let ok = XcodeTools.BuildOutcome(
            summary: XcodebuildSummary(outcome: .buildSucceeded, errors: [], warnings: [], testCounts: nil),
            exitCode: 0, timedOut: false, rawTail: "noise")
        XCTAssertFalse(ok.description.contains("output tail"))
    }

    func testDescribeIncludesEssentials() {
        let summary = XcodebuildSummary(
            outcome: .testFailed,
            errors: ["e1"],
            warnings: ["w1", "w2"],
            testCounts: .init(executed: 3, failures: 2)
        )
        let text = XcodebuildOutputParser.describe(summary, exitCode: 65, timedOut: false)
        XCTAssertTrue(text.contains("TEST FAILED"))
        XCTAssertTrue(text.contains("exit code 65"))
        XCTAssertTrue(text.contains("3 executed, 2 failed"))
        XCTAssertTrue(text.contains("e1"))

        let timedOut = XcodebuildOutputParser.describe(summary, exitCode: 15, timedOut: true)
        XCTAssertTrue(timedOut.contains("TIMED OUT"))
    }
}
