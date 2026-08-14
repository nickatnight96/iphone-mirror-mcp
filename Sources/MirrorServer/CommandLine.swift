import Foundation
import MirrorCore

/// The binary's command-line surface.
///
/// The default (no arguments) is the stdio MCP server, because that is how
/// every MCP client launches it. The other subcommands exist for the human
/// setting that up: an MCP server started by hand looks identical to a hung
/// process — it waits silently on stdin for a JSON-RPC frame that never
/// comes — so without `--version` and `doctor` there is no way to confirm the
/// binary works before wiring it into a client and hoping.
public enum CLI {
    public enum Command: Equatable {
        case serve
        case doctor
        case version
        case help
        /// An argument the parser does not recognize.
        case unknown(String)
    }

    /// Exit codes. `doctor` distinguishes "ran fine, setup is broken" (1)
    /// from "you typed something wrong" (2) so scripts can tell them apart.
    public enum ExitCode {
        public static let ok: Int32 = 0
        public static let checksFailed: Int32 = 1
        public static let usage: Int32 = 2
    }

    /// Parses arguments *excluding* the executable path.
    public static func parse(_ arguments: [String]) -> Command {
        guard let first = arguments.first else { return .serve }
        switch first {
        case "serve", "--serve":
            return .serve
        case "doctor", "--doctor":
            return .doctor
        case "--version", "-v", "version":
            return .version
        case "--help", "-h", "help":
            return .help
        default:
            return .unknown(first)
        }
    }

    public static var versionLine: String {
        "\(MirrorMCPServer.name) \(MirrorMCPServer.version)"
    }

    public static var helpText: String {
        """
        \(versionLine)

        An MCP server that drives a real iPhone through the macOS iPhone
        Mirroring app, and runs Xcode builds/tests on simulators and devices.

        USAGE
          iphone-mirror-mcp              Start the MCP server on stdio (default).
                                         MCP clients invoke the binary this way;
                                         run by hand it waits silently for input.
          iphone-mirror-mcp doctor       Check permissions and the mirroring
                                         session, then exit. Run this FIRST.
          iphone-mirror-mcp --version    Print the version and exit.
          iphone-mirror-mcp --help       Print this help and exit.

        SETUP
          This server needs macOS permissions granted to whichever app LAUNCHES
          it — your terminal, or the desktop app hosting the MCP client — not to
          the binary itself:

            Accessibility      System Settings → Privacy & Security → Accessibility
            Screen Recording   System Settings → Privacy & Security → Screen & System Audio Recording
            Automation         granted on first use (System Events)

          `doctor` verifies all of them end to end, including whether synthetic
          input is actually being delivered.

        CONNECTING A CLIENT
          Any MCP client that speaks stdio works. Point it at this binary with
          no arguments, for example:

            {"mcpServers": {"iphone-mirror": {"command": "/path/to/iphone-mirror-mcp"}}}

          See docs/getting-started.md for per-client configuration.

        EXIT CODES
          0  success
          1  doctor ran, but one or more checks failed
          2  bad usage
        """
    }

    /// Runs the command and returns the process exit code. `serve` only
    /// returns when the client disconnects.
    public static func run(_ arguments: [String]) async throws -> Int32 {
        switch parse(arguments) {
        case .serve:
            try await MirrorMCPServer.run()
            return ExitCode.ok

        case .version:
            print(versionLine)
            return ExitCode.ok

        case .help:
            print(helpText)
            return ExitCode.ok

        case .doctor:
            let report = await MirrorSession().doctor()
            print(report.describe())
            let healthy = report.accessibility && report.screenRecording && report.postEventAccess
            if !healthy {
                print("")
                print("Some checks failed. Grant the permissions above to the app that")
                print("launches this server, then run `iphone-mirror-mcp doctor` again.")
            }
            return healthy ? ExitCode.ok : ExitCode.checksFailed

        case .unknown(let argument):
            FileHandle.standardError.write(Data("Unknown argument \"\(argument)\".\n\n".utf8))
            FileHandle.standardError.write(Data((helpText + "\n").utf8))
            return ExitCode.usage
        }
    }
}
