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
        mode: ServeMode = .full,
        session: MirrorSession = MirrorSession(),
        _ body: (Client) async throws -> Void
    ) async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await MirrorMCPServer.makeServer(session: session, mode: mode)
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
        try await withConnectedClient(mode: .read, session: Self.inUseSession()) { client in
            let (content, isError) = try await client.callTool(name: "status", arguments: [:])
            XCTAssertNotEqual(isError, true)
            XCTAssertEqual(content.count, 2, "status should carry the paused note as a second item")
            guard case .text(let note, _, _)? = content.last else {
                return XCTFail("expected a text note")
            }
            XCTAssertTrue(note.contains("paused"), note)
        }
        try await withConnectedClient(mode: .full, session: Self.inUseSession()) { client in
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

    // MARK: - Modes

    func testReadModeListsOnlyReadTools() async throws {
        try await withConnectedClient(mode: .read) { client in
            let (tools, _) = try await client.listTools()
            XCTAssertEqual(tools.count, 15)
            XCTAssertTrue(tools.contains { $0.name == "screenshot" })
            XCTAssertFalse(tools.contains { $0.name == "tap" })
            for tool in tools {
                XCTAssertEqual(tool.annotations.readOnlyHint, true, tool.name)
            }
        }
    }

    func testInputModeHidesFullTools() async throws {
        try await withConnectedClient(mode: .input) { client in
            let (tools, _) = try await client.listTools()
            XCTAssertEqual(tools.count, 34)
            XCTAssertTrue(tools.contains { $0.name == "tap" })
            XCTAssertFalse(tools.contains { $0.name == "mirror_restart" })
            XCTAssertFalse(tools.contains { $0.name == "run_on_iphone" })
        }
    }

    /// A hidden tool is not merely unlisted: calling it by name is refused
    /// the same way a tool that never existed is.
    func testHiddenToolIsUnknownInReadMode() async throws {
        try await withConnectedClient(mode: .read) { client in
            let (content, isError) = try await client.callTool(name: "tap", arguments: ["x": 10, "y": 10])
            XCTAssertEqual(isError, true)
            guard case .text(let text, _, _)? = content.first else {
                return XCTFail("expected text content")
            }
            XCTAssertTrue(text.contains("Unknown tool"), text)
        }
    }

    func testAnnotationsTravelOverTheWire() async throws {
        try await withConnectedClient(mode: .full) { client in
            let (tools, _) = try await client.listTools()
            XCTAssertEqual(tools.count, 63)
            let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
            let screenshot = try XCTUnwrap(byName["screenshot"])
            XCTAssertEqual(screenshot.annotations.readOnlyHint, true)
            XCTAssertEqual(screenshot.annotations.destructiveHint, false)
            XCTAssertEqual(screenshot.annotations.openWorldHint, false)
            let tap = try XCTUnwrap(byName["tap"])
            XCTAssertEqual(tap.annotations.readOnlyHint, false)
            XCTAssertEqual(tap.annotations.destructiveHint, true)
            XCTAssertEqual(tap.annotations.idempotentHint, false)
            let build = try XCTUnwrap(byName["xcode_build"])
            XCTAssertEqual(build.annotations.openWorldHint, true)
            XCTAssertEqual(build.title, "Xcode Build")
        }
    }
}
