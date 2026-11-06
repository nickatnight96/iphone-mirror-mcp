import XCTest
import MCP
@testable import MirrorCore
@testable import MirrorServer

/// Full MCP protocol round-trips: a real Client and the real server talking
/// over an in-memory transport. No phone, permissions, or Xcode needed —
/// tools that touch hardware are exercised only through paths that fail
/// gracefully (unknown tool, bad arguments).
final class EndToEndProtocolTests: XCTestCase {
    func withConnectedClient(
        session: MirrorSession = MirrorSession(),
        _ body: (Client) async throws -> Void
    ) async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await MirrorMCPServer.makeServer(session: session)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0")
        _ = try await client.connect(transport: clientTransport)
        do {
            try await body(client)
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
        await client.disconnect()
        await server.stop()
    }

    func testInitializeAndListTools() async throws {
        try await withConnectedClient { client in
            let (tools, _) = try await client.listTools()
            XCTAssertGreaterThanOrEqual(tools.count, 30)
            XCTAssertTrue(tools.contains { $0.name == "screenshot" })
            XCTAssertTrue(tools.contains { $0.name == "run_on_iphone" })
            // Every tool must expose an object schema over the wire.
            for tool in tools {
                XCTAssertEqual(tool.inputSchema.objectValue?["type"]?.stringValue, "object", tool.name)
            }
        }
    }

    func testUnknownToolReturnsIsError() async throws {
        try await withConnectedClient { client in
            let (content, isError) = try await client.callTool(name: "no_such_tool", arguments: [:])
            XCTAssertEqual(isError, true)
            guard case .text(let text, _, _)? = content.first else {
                return XCTFail("expected text content")
            }
            XCTAssertTrue(text.contains("no_such_tool"))
        }
    }

    func testMissingRequiredArgumentReturnsIsError() async throws {
        try await withConnectedClient { client in
            let (content, isError) = try await client.callTool(name: "tap", arguments: [:])
            XCTAssertEqual(isError, true)
            guard case .text(let text, _, _)? = content.first else {
                return XCTFail("expected text content")
            }
            XCTAssertTrue(text.contains("x"), "error should name the missing parameter: \(text)")
        }
    }

    func testRecordScreenRejectsMissingRequiredSeconds() async throws {
        // "seconds" is schema-required; the handler must enforce it rather
        // than silently defaulting.
        try await withConnectedClient { client in
            let (_, isError) = try await client.callTool(name: "record_screen", arguments: [:])
            XCTAssertEqual(isError, true)
        }
    }

    func testStatusToolWorksWithoutHardware() async throws {
        try await withConnectedClient { client in
            let (content, isError) = try await client.callTool(name: "status", arguments: [:])
            XCTAssertNotEqual(isError, true)
            guard case .text(let text, _, _)? = content.first else {
                return XCTFail("expected text content")
            }
            XCTAssertTrue(text.contains("Session:"), text)
            XCTAssertTrue(text.contains("Accessibility"), text)
        }
    }

    /// A session that is paused with "iPhone in Use" on screen. A screenshot
    /// needs a real window and Screen Recording, so the paused note is
    /// checked on status.
    static func inUseSession() -> MirrorSession {
        MirrorSession(probe: MirrorSession.SessionProbe(
            state: { .paused },
            overlay: { .inUse },
            pressResume: { XCTFail("software must not press through iPhone in Use"); return false },
            clickResume: { XCTFail("software must not click through iPhone in Use"); return false }))
    }

    func testPausedNoteAndRefusalOverProtocol() async throws {
        try await withConnectedClient(session: Self.inUseSession()) { client in
            let (content, isError) = try await client.callTool(name: "status", arguments: [:])
            XCTAssertNotEqual(isError, true)
            XCTAssertEqual(content.count, 2, "status should carry the paused note as a second item")
            guard case .text(let note, _, _)? = content.last else {
                return XCTFail("expected a text note")
            }
            XCTAssertTrue(note.contains("paused"), note)

            for (name, arguments) in [
                ("tap", ["x": 10, "y": 10] as [String: Value]),
                ("notification_click", [:]),
                ("batch", ["steps": [["tool": "home"]]]),
            ] {
                let (content, isError) = try await client.callTool(name: name, arguments: arguments)
                XCTAssertEqual(isError, true, name)
                guard case .text(let text, _, _)? = content.first else {
                    return XCTFail("\(name): expected text content")
                }
                XCTAssertTrue(text.contains("paused"), "\(name): \(text)")
            }
        }
    }
}
