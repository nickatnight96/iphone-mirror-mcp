import XCTest
import MCP
@testable import MirrorCore
@testable import MirrorServer

final class ToolCatalogTests: XCTestCase {
    func allTools() -> [RegisteredTool] {
        MirrorMCPServer.allTools(session: MirrorSession())
    }

    func testToolNamesAreUnique() {
        let names = allTools().map(\.tool.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate tool names: \(names)")
    }

    func testExpectedToolCountAndFlagship() {
        let names = Set(allTools().map(\.tool.name))
        XCTAssertGreaterThanOrEqual(names.count, 30, "expected a rich tool surface, got \(names.count)")
        for required in [
            "status", "mirror_launch", "screenshot", "tap", "double_tap", "long_press",
            "swipe", "drag", "type_text", "press_key", "home", "app_switcher", "spotlight",
            "launch_app", "open_url", "shake", "read_screen", "find_text", "tap_text",
            "wait_for_text", "scroll_to", "record_screen",
            "xcode_list", "xcode_build", "xcode_test", "devices", "device_install",
            "device_launch", "run_on_iphone", "sim_boot", "sim_install", "sim_launch",
            "sim_terminate", "sim_screenshot", "sim_openurl",
        ] {
            XCTAssertTrue(names.contains(required), "missing tool \(required)")
        }
    }

    func testEverySchemaIsAnObjectWithValidRequiredKeys() throws {
        for registered in allTools() {
            let schema = registered.tool.inputSchema
            let object = schema.objectValue
            XCTAssertNotNil(object, "\(registered.tool.name): inputSchema is not an object")
            XCTAssertEqual(object?["type"]?.stringValue, "object", registered.tool.name)
            let properties = object?["properties"]?.objectValue ?? [:]
            if let required = object?["required"]?.arrayValue {
                for key in required {
                    let keyName = try XCTUnwrap(key.stringValue)
                    XCTAssertNotNil(
                        properties[keyName],
                        "\(registered.tool.name): required key \(keyName) missing from properties")
                }
            }
        }
    }

    func testEveryToolHasNonEmptyDescription() {
        for registered in allTools() {
            XCTAssertFalse(
                (registered.tool.description ?? "").isEmpty,
                "\(registered.tool.name) has no description")
        }
    }

    func testSchemasSerializeToJSON() throws {
        for registered in allTools() {
            let data = try JSONEncoder().encode(registered.tool.inputSchema)
            XCTAssertFalse(data.isEmpty, registered.tool.name)
        }
    }
}

final class ToolArgsTests: XCTestCase {
    func testStringAccessors() throws {
        let args = ToolArgs(["name": "hi"])
        XCTAssertEqual(try args.string("name"), "hi")
        XCTAssertNil(try args.optionalString("missing"))
        XCTAssertThrowsError(try args.string("missing"))
    }

    func testNumericCoercionAcceptsIntAndDouble() throws {
        let args = ToolArgs(["a": 200, "b": 200.5])
        XCTAssertEqual(try args.double("a"), 200)
        XCTAssertEqual(try args.double("b"), 200.5)
        XCTAssertEqual(try args.int("a", default: 0), 200)
        XCTAssertEqual(try args.int("missing", default: 7), 7)
    }

    func testBoolAndArray() throws {
        let args = ToolArgs(["flag": true, "list": ["x", "y"]])
        XCTAssertTrue(try args.bool("flag", default: false))
        XCTAssertFalse(try args.bool("missing", default: false))
        XCTAssertEqual(try args.stringArray("list"), ["x", "y"])
        XCTAssertEqual(try args.stringArray("missing"), [])
    }

    func testTypeErrorsAreMirrorErrors() {
        let args = ToolArgs(["x": "not a number"])
        XCTAssertThrowsError(try args.double("x")) { error in
            XCTAssertTrue(error is MirrorError)
        }
    }

    func testOutOfRangeIntThrowsInsteadOfTrapping() {
        // Int(1e300) is a fatal trap — one bad argument must not kill the server.
        let args = ToolArgs(["x": 1e300, "y": -1e300])
        XCTAssertThrowsError(try args.int("x", default: 0)) { XCTAssertTrue($0 is MirrorError) }
        XCTAssertThrowsError(try args.optionalInt("y")) { XCTAssertTrue($0 is MirrorError) }
        XCTAssertThrowsError(try args.int("x")) { XCTAssertTrue($0 is MirrorError) }
    }

    func testRequiredIntAccessor() throws {
        let args = ToolArgs(["seconds": 30])
        XCTAssertEqual(try args.int("seconds"), 30)
        XCTAssertThrowsError(try args.int("missing"))
    }

    func testNullTreatedAsMissing() throws {
        let args = ToolArgs(["x": nil])
        XCTAssertNil(try args.optionalString("x"))
        XCTAssertNil(try args.optionalDouble("x"))
    }

    func testErrorResultShape() {
        let result = errorResult(MirrorError("boom", remediation: "fix it"))
        XCTAssertEqual(result.isError, true)
        guard case .text(let text, _, _)? = result.content.first else {
            return XCTFail("expected text content")
        }
        XCTAssertTrue(text.contains("boom"))
        XCTAssertTrue(text.contains("fix it"))
    }

    func testImageResultShape() throws {
        let result = imageResult(pngData: Data([1, 2, 3]), caption: "cap")
        XCTAssertEqual(result.content.count, 2)
        guard case .image(let data, let mime, _, _) = result.content[1] else {
            return XCTFail("expected image content")
        }
        XCTAssertEqual(mime, "image/png")
        XCTAssertEqual(Data(base64Encoded: data), Data([1, 2, 3]))
    }
}

final class BuildRequestTests: XCTestCase {
    func testBuildRequestFromArgs() throws {
        let args = ToolArgs([
            "scheme": "MyApp",
            "project_path": "/tmp/My.xcodeproj",
            "configuration": "Release",
            "extra_args": ["-quiet"],
            "timeout_seconds": 60,
        ])
        let request = try XcodeToolCatalog.buildRequest(from: args)
        XCTAssertEqual(request.scheme, "MyApp")
        XCTAssertEqual(request.configuration, "Release")
        XCTAssertEqual(request.timeoutSeconds, 60)
        let arguments = request.arguments(action: ["build"])
        XCTAssertTrue(arguments.contains("-project"))
        XCTAssertTrue(arguments.contains("/tmp/My.xcodeproj"))
        XCTAssertTrue(arguments.contains("-quiet"))
        XCTAssertEqual(arguments.last, "build")
    }

    func testWorkspaceAndDirectoryContainers() {
        XCTAssertEqual(
            XcodeTools.containerArguments(projectPath: "/a/B.xcworkspace"),
            ["-workspace", "/a/B.xcworkspace"])
        XCTAssertEqual(
            XcodeTools.containerArguments(projectPath: "/a/B.xcodeproj"),
            ["-project", "/a/B.xcodeproj"])
        XCTAssertEqual(XcodeTools.containerArguments(projectPath: "/a/dir"), [])
        XCTAssertEqual(XcodeTools.containerArguments(projectPath: nil), [])
        XCTAssertEqual(XcodeTools.workingDirectory(projectPath: "/a/B.xcodeproj"), "/a")
        XCTAssertEqual(XcodeTools.workingDirectory(projectPath: "/a/dir"), "/a/dir")
    }

    func testOnlyTestingArgumentsPrecedeTestAction() async throws {
        let request = XcodeTools.BuildRequest(scheme: "S")
        let arguments = request.arguments(action: ["-only-testing:Target/Case", "test"])
        XCTAssertTrue(arguments.contains("-only-testing:Target/Case"))
        XCTAssertEqual(arguments.last, "test")
    }
}
