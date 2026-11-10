import Foundation
import MCP
import MirrorCore

/// The stdio MCP server: registers every tool and serves until the client
/// disconnects. All logging goes to stderr — stdout is the protocol channel.
public enum MirrorMCPServer {
    public static let name = "iphone-mirror-mcp"
    public static let version = "1.0.1"

    static func instructions(mode: ServeMode) -> String {
        """
        Drive a real iPhone through the built-in macOS iPhone Mirroring app, and run \
        Xcode builds/tests on simulators and physical devices.

        Coordinate contract: every x/y is a pixel position in the most recent screenshot \
        (origin top-left). Typical flow: screenshot → find the element (visually or via \
        read_screen/find_text) → tap/swipe → screenshot to verify.

        The mirroring session needs the iPhone paired, nearby, and locked. If a tool \
        reports the session paused, a person must resume it (lock the iPhone and leave it \
        near the Mac, or click Resume in the iPhone Mirroring window); this server never \
        clicks past a pause. If a tool reports the session not running, call mirror_launch \
        and check status. \
        Input tools need the Accessibility permission; capture needs Screen Recording — \
        status reports both.

        \(modeNote(mode))

        For on-device app testing: run_on_iphone builds, installs, and launches your \
        scheme on the paired iPhone; then use the mirroring tools to operate the app \
        and verify behavior on the mirrored screen.
        """
    }

    static func modeNote(_ mode: ServeMode) -> String {
        switch mode {
        case .read:
            return "This server runs in read mode: only tools that observe the phone, devices, and simulators are listed. Input and management tools need a restart with --mode input or --mode full."
        case .input:
            return "This server runs in input mode: observation and input tools are listed. mirror_launch, mirror_restart, recordings, Xcode builds, and device and simulator management need a restart with --mode full."
        case .full:
            return "This server runs in full mode: every tool is listed."
        }
    }

    public static func allTools(session: MirrorSession) -> [RegisteredTool] {
        MirroringTools.all(session: session) + XcodeToolCatalog.all()
    }

    /// Builds the MCP server with the tools `mode` allows. A hidden tool is
    /// absent from tools/list and, when called by name anyway, answers
    /// "Unknown tool" exactly like a tool that never existed. Separated from
    /// run() so tests can start it on an in-memory transport.
    public static func makeServer(session: MirrorSession, mode: ServeMode) async -> Server {
        let mirroring = MirroringTools.all(session: session)
        let xcode = XcodeToolCatalog.all()
        let visible = (mirroring + xcode).filter { mode.allows($0.access) }
        let byName = Dictionary(uniqueKeysWithValues: visible.map { ($0.tool.name, $0) })
        let toolList = visible.map(\.tool)
        // Mirroring tools are strictly FIFO — interleaved gestures/captures
        // corrupt each other. Xcode/simulator tools stay concurrent.
        let mirroringNames = Set(mirroring.map(\.tool.name))
        let serializer = ToolSerializer()

        let server = Server(
            name: name,
            version: version,
            instructions: instructions(mode: mode),
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolList)
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = byName[params.name] else {
                return errorResult(MirrorError("Unknown tool \"\(params.name)\"."))
            }
            let args = ToolArgs(params.arguments ?? [:])
            do {
                if mirroringNames.contains(params.name) {
                    let result = try await serializer.run { try await tool.handler(args) }
                    // A tool that ran while the pause latch is set (reads do)
                    // says so, because a caller that only looks at
                    // screenshots has no other way to learn why its next
                    // tap will be refused. Result.content is immutable, so
                    // the result is rebuilt with one more text item.
                    if result.isError != true, await session.pauseLatched {
                        return CallTool.Result(
                            content: result.content + [.text(text: MirrorSession.pausedNote, annotations: nil, _meta: nil)],
                            structuredContent: result.structuredContent,
                            isError: result.isError,
                            _meta: result._meta)
                    }
                    return result
                }
                return try await tool.handler(args)
            } catch {
                return errorResult(error)
            }
        }

        return server
    }

    public static func run(mode: ServeMode) async throws {
        let session = MirrorSession()
        let server = await makeServer(session: session, mode: mode)
        FileHandle.standardError.write(Data("\(name) \(version) ready (mode: \(mode.rawValue))\n".utf8))
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
