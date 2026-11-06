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
        case serve(mode: ServeMode)
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
        guard let first = arguments.first else { return .serve(mode: .read) }
        switch first {
        case "serve", "--serve":
            return parseServe(Array(arguments.dropFirst()))
        case "--mode":
            return parseServe(arguments)
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

    /// The serve command's own arguments: nothing (read mode) or `--mode`
    /// with one of the ServeMode values. A bad or missing value is a usage
    /// error, never a fallback to some mode: a typo must not hand out phone
    /// control.
    static func parseServe(_ arguments: [String]) -> Command {
        guard let flag = arguments.first else { return .serve(mode: .read) }
        guard flag == "--mode" else { return .unknown(flag) }
        guard let value = arguments.dropFirst().first else { return .unknown("--mode") }
        guard let mode = ServeMode(rawValue: value) else { return .unknown("--mode \(value)") }
        return .serve(mode: mode)
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
          iphone-mirror-mcp              Start the MCP server on stdio (default,
                                         read mode). MCP clients invoke the binary
                                         this way; run by hand it waits silently
                                         for input.
          iphone-mirror-mcp --mode MODE  Same, with the tool set MODE picks: read
                                         (default), input, or full. See MODES.
          iphone-mirror-mcp doctor       Check permissions and the mirroring
                                         session, then exit. Run this FIRST.
          iphone-mirror-mcp --version    Print the version and exit.
          iphone-mirror-mcp --help       Print this help and exit.

        MODES
          The mode decides which tools the server lists. A hidden tool is absent
          from tools/list and answers "Unknown tool" if called anyway. Changing
          the mode takes a restart; a model cannot switch it.

            read    status, screenshot, OCR, find, wait, notifications, and the
                    Xcode, device, and simulator listings. Nothing is sent to
                    the phone. This is the default.
            input   read plus taps, swipes, typing, keys, navigation, batch, and
                    notification_click.
            full    every tool: mirror_launch, mirror_restart, recordings, Xcode
                    builds and tests, device and simulator management.

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
          Any MCP client that speaks stdio works. Point it at this binary, with
          --mode as the arguments when the model should do more than look:

            {"mcpServers": {"iphone-mirror": {"command": "/path/to/iphone-mirror-mcp",
                                              "args": ["--mode", "input"]}}}

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
        case .serve(let mode):
            try await MirrorMCPServer.run(mode: mode)
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
