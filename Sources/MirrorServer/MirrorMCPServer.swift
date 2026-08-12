import Foundation
import MCP
import MirrorCore

/// The stdio MCP server: registers every tool and serves until the client
/// disconnects. All logging goes to stderr — stdout is the protocol channel.
public enum MirrorMCPServer {
    public static let name = "iphone-mirror-mcp"
    public static let version = "0.1.0"

    static let instructions = """
        Drive a real iPhone through the built-in macOS iPhone Mirroring app, and run \
        Xcode builds/tests on simulators and physical devices.

        Coordinate contract: every x/y is a pixel position in the most recent screenshot \
        (origin top-left). Typical flow: screenshot → find the element (visually or via \
        read_screen/find_text) → tap/swipe → screenshot to verify.

        The mirroring session needs the iPhone paired, nearby, and locked. If a tool \
        reports the session paused or not running, call mirror_launch and check status. \
        Input tools need the Accessibility permission; capture needs Screen Recording — \
        status reports both.

        For on-device app testing: run_on_iphone builds, installs, and launches your \
        scheme on the paired iPhone; then use the mirroring tools to operate the app \
        and verify behavior on the mirrored screen.
        """

    public static func allTools(session: MirrorSession) -> [RegisteredTool] {
        MirroringTools.all(session: session) + XcodeToolCatalog.all()
    }

    /// Builds the MCP server with every tool registered. Separated from
    /// run() so tests can start it on an in-memory transport.
    public static func makeServer(session: MirrorSession) async -> Server {
        let mirroring = MirroringTools.all(session: session)
        let xcode = XcodeToolCatalog.all()
        let registered = mirroring + xcode
        let byName = Dictionary(uniqueKeysWithValues: registered.map { ($0.tool.name, $0) })
        let toolList = registered.map(\.tool)
        // Mirroring tools are strictly FIFO — interleaved gestures/captures
        // corrupt each other. Xcode/simulator tools stay concurrent.
        let mirroringNames = Set(mirroring.map(\.tool.name))
        let serializer = ToolSerializer()

        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
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
                    return try await serializer.run { try await tool.handler(args) }
                }
                return try await tool.handler(args)
            } catch {
                return errorResult(error)
            }
        }

        return server
    }

    public static func run() async throws {
        let session = MirrorSession()
        let server = await makeServer(session: session)
        FileHandle.standardError.write(Data("\(name) \(version) ready\n".utf8))
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
