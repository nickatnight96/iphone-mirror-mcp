import Foundation

/// Condensed result of an xcodebuild invocation, so tool output stays small
/// even when the raw log is hundreds of kilobytes.
public struct XcodebuildSummary: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case buildSucceeded = "BUILD SUCCEEDED"
        case buildFailed = "BUILD FAILED"
        case testSucceeded = "TEST SUCCEEDED"
        case testFailed = "TEST FAILED"
        case cleanSucceeded = "CLEAN SUCCEEDED"
        case unknown = "UNKNOWN"
    }

    public struct TestCounts: Equatable, Sendable {
        public let executed: Int
        public let failures: Int
        public init(executed: Int, failures: Int) {
            self.executed = executed
            self.failures = failures
        }
    }

    public let outcome: Outcome
    public let errors: [String]
    public let warnings: [String]
    public let testCounts: TestCounts?

    public init(outcome: Outcome, errors: [String], warnings: [String], testCounts: TestCounts?) {
        self.outcome = outcome
        self.errors = errors
        self.warnings = warnings
        self.testCounts = testCounts
    }
}

public enum XcodebuildOutputParser {
    static let maxIssues = 50

    public static func parse(_ output: String) -> XcodebuildSummary {
        var outcome: XcodebuildSummary.Outcome = .unknown
        var errors: [String] = []
        var warnings: [String] = []
        var seenErrors = Set<String>()
        var seenWarnings = Set<String>()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Outcome markers: the last one printed wins (xcodebuild prints one
            // per action, and the final action's marker reflects the run).
            if line.contains("** BUILD SUCCEEDED **") { outcome = .buildSucceeded }
            else if line.contains("** BUILD FAILED **") { outcome = .buildFailed }
            else if line.contains("** TEST SUCCEEDED **") { outcome = .testSucceeded }
            else if line.contains("** TEST FAILED **") { outcome = .testFailed }
            else if line.contains("** CLEAN SUCCEEDED **") { outcome = .cleanSucceeded }

            if line.contains("error: ") || line.hasPrefix("xcodebuild: error") {
                if errors.count < maxIssues, seenErrors.insert(line).inserted {
                    errors.append(line)
                }
            } else if line.contains("warning: ") {
                if warnings.count < maxIssues, seenWarnings.insert(line).inserted {
                    warnings.append(line)
                }
            }
        }

        return XcodebuildSummary(
            outcome: outcome,
            errors: errors,
            warnings: warnings,
            testCounts: parseTestCounts(output)
        )
    }

    /// Extracts aggregate test counts. Handles both XCTest
    /// ("Executed 12 tests, with 1 failure") — taking the LAST occurrence,
    /// which is the all-tests aggregate — and Swift Testing
    /// ("Test run with 5 tests passed/failed after …").
    static func parseTestCounts(_ output: String) -> XcodebuildSummary.TestCounts? {
        let xctest = /Executed (\d+) tests?, with (\d+) failures?/
        var last: XcodebuildSummary.TestCounts?
        for match in output.matches(of: xctest) {
            if let executed = Int(match.1), let failures = Int(match.2) {
                last = .init(executed: executed, failures: failures)
            }
        }
        if let last { return last }

        let swiftTesting = /Test run with (\d+) tests? (?:in \d+ suites? )?(passed|failed)/
        if let match = output.matches(of: swiftTesting).last, let executed = Int(match.1) {
            // Swift Testing does not print an aggregate failure count on the
            // summary line; report 0 for passed and -1 (unknown) is avoided by
            // counting individual "failed" issue lines instead.
            if match.2 == "passed" {
                return .init(executed: executed, failures: 0)
            }
            let failedCases = output.matches(of: /✘ Test .* failed/).count
            return .init(executed: executed, failures: max(failedCases, 1))
        }
        return nil
    }

    /// Renders a summary as compact human/LLM-readable text.
    public static func describe(_ summary: XcodebuildSummary, exitCode: Int32, timedOut: Bool) -> String {
        var lines: [String] = []
        if timedOut {
            lines.append("RESULT: TIMED OUT (process was killed before finishing)")
        } else {
            lines.append("RESULT: \(summary.outcome.rawValue) (exit code \(exitCode))")
        }
        if let counts = summary.testCounts {
            lines.append("TESTS: \(counts.executed) executed, \(counts.failures) failed")
        }
        if !summary.errors.isEmpty {
            lines.append("ERRORS (\(summary.errors.count)):")
            lines.append(contentsOf: summary.errors.map { "  " + $0 })
        }
        if !summary.warnings.isEmpty {
            lines.append("WARNINGS: \(summary.warnings.count) (first 5 shown)")
            lines.append(contentsOf: summary.warnings.prefix(5).map { "  " + $0 })
        }
        return lines.joined(separator: "\n")
    }
}
