import XCTest
@testable import MirrorServer

/// The CLI is the first thing a new user touches, and the only way to tell a
/// working binary from a hung one before an MCP client is wired up. These
/// tests pin the contract the docs promise.
final class CommandLineTests: XCTestCase {

    // MARK: - Parsing

    /// The default MUST stay `serve`: every MCP client launches the binary
    /// with no arguments, so any other default silently breaks all of them.
    func testNoArgumentsServes() {
        XCTAssertEqual(CLI.parse([]), .serve)
    }

    func testRecognizedCommands() {
        XCTAssertEqual(CLI.parse(["serve"]), .serve)
        XCTAssertEqual(CLI.parse(["--serve"]), .serve)
        XCTAssertEqual(CLI.parse(["doctor"]), .doctor)
        XCTAssertEqual(CLI.parse(["--doctor"]), .doctor)
        XCTAssertEqual(CLI.parse(["version"]), .version)
        XCTAssertEqual(CLI.parse(["--version"]), .version)
        XCTAssertEqual(CLI.parse(["-v"]), .version)
        XCTAssertEqual(CLI.parse(["help"]), .help)
        XCTAssertEqual(CLI.parse(["--help"]), .help)
        XCTAssertEqual(CLI.parse(["-h"]), .help)
    }

    func testUnknownArgumentIsReported() {
        XCTAssertEqual(CLI.parse(["--nope"]), .unknown("--nope"))
        XCTAssertEqual(CLI.parse(["screenshot"]), .unknown("screenshot"))
        // The offending argument is carried so the error can name it.
        guard case .unknown(let argument) = CLI.parse(["--verbose", "extra"]) else {
            return XCTFail("expected .unknown")
        }
        XCTAssertEqual(argument, "--verbose")
    }

    // MARK: - Output contracts

    func testVersionLineCarriesNameAndVersion() {
        XCTAssertEqual(CLI.versionLine, "\(MirrorMCPServer.name) \(MirrorMCPServer.version)")
        XCTAssertTrue(CLI.versionLine.contains("iphone-mirror-mcp"))
        // A bare name with no version would defeat the point of the flag.
        XCTAssertTrue(CLI.versionLine.contains("."), "expected a dotted version in \(CLI.versionLine)")
    }

    /// The help text is the setup instructions for anyone who runs the binary
    /// by hand. These are the specific things a stuck user needs from it.
    func testHelpTextCoversSetupEssentials() {
        let help = CLI.helpText
        for expected in ["doctor", "Accessibility", "Screen Recording", "stdio", "mcpServers"] {
            XCTAssertTrue(help.contains(expected), "help text is missing \"\(expected)\"")
        }
        XCTAssertTrue(help.contains(MirrorMCPServer.version), "help text should state the version")
    }

    /// Exit codes must stay distinguishable: a failing environment (1) is a
    /// different problem from a typo (2), and scripts branch on that.
    func testExitCodesAreDistinct() {
        XCTAssertEqual(CLI.ExitCode.ok, 0)
        XCTAssertNotEqual(CLI.ExitCode.checksFailed, CLI.ExitCode.ok)
        XCTAssertNotEqual(CLI.ExitCode.usage, CLI.ExitCode.ok)
        XCTAssertNotEqual(CLI.ExitCode.usage, CLI.ExitCode.checksFailed)
    }

    // MARK: - Execution

    func testVersionAndHelpExitZero() async throws {
        let version = try await CLI.run(["--version"])
        XCTAssertEqual(version, CLI.ExitCode.ok)
        let help = try await CLI.run(["--help"])
        XCTAssertEqual(help, CLI.ExitCode.ok)
    }

    func testUnknownArgumentExitsWithUsageCode() async throws {
        let code = try await CLI.run(["--definitely-not-a-flag"])
        XCTAssertEqual(code, CLI.ExitCode.usage)
    }

    /// `doctor` must always terminate with a real report rather than hanging
    /// or trapping, whatever the machine's permission state — it is the tool
    /// people reach for precisely when things are broken.
    func testDoctorRunsToCompletionAndReportsAVerdict() async throws {
        let code = try await CLI.run(["doctor"])
        XCTAssertTrue(code == CLI.ExitCode.ok || code == CLI.ExitCode.checksFailed,
                      "doctor returned \(code); expected a pass/fail verdict")
    }
}
