import Foundation
import MCP
import MirrorCore

/// Tools for Xcode builds, physical devices (devicectl), and simulators
/// (simctl) — the automated-testing half of the server. The flagship flow:
/// run_on_iphone builds and launches an app on the paired iPhone, then the
/// mirroring tools drive and verify it on-device.
enum XcodeToolCatalog {
    static func all() -> [RegisteredTool] {
        let buildProperties: [String: Value] = [
            "project_path": ["type": "string", "description": "Path to a .xcodeproj, .xcworkspace, or a package/project directory. Omit to use the current directory."],
            "scheme": ["type": "string", "description": "Xcode scheme to build. Run xcode_list to see the available schemes"],
            "configuration": ["type": "string", "description": "Debug (default) or Release"],
            "destination": ["type": "string", "description": "xcodebuild -destination string, e.g. \"platform=iOS Simulator,name=iPhone 17 Pro\" or \"platform=iOS,id=<udid>\""],
            "extra_args": ["type": "array", "items": ["type": "string"], "description": "Additional xcodebuild arguments"],
            "timeout_seconds": ["type": "number", "description": "Default 900, max 3600"],
        ]

        return [
            RegisteredTool(
                name: "xcode_list",
                description: "List the schemes, targets, and build configurations of an Xcode project/workspace (xcodebuild -list -json).",
                schema: [
                    "type": "object",
                    "properties": [
                        "project_path": ["type": "string", "description": "Path to .xcodeproj/.xcworkspace or the project directory (default: current directory)"],
                    ],
                ]
            ) { args in
                textResult(try await XcodeTools.list(projectPath: try args.optionalString("project_path")))
            },

            RegisteredTool(
                name: "xcode_build",
                description: "Build an Xcode scheme and return a condensed summary (outcome, errors, warnings). Long logs are parsed down to what matters.",
                schema: ["type": "object", "properties": .object(buildProperties), "required": ["scheme"]]
            ) { args in
                let outcome = try await XcodeTools.build(try buildRequest(from: args))
                return textResult(outcome.description)
            },

            RegisteredTool(
                name: "xcode_test",
                description: "Run an Xcode scheme's tests and return a condensed summary with test counts and failures. Defaults to the booted simulator when no destination is given. only_testing narrows to specific tests (Target/Class/testMethod).",
                schema: [
                    "type": "object",
                    "properties": .object(buildProperties.merging([
                        "only_testing": ["type": "array", "items": ["type": "string"], "description": "Limit to these test identifiers"],
                    ]) { a, _ in a }),
                    "required": ["scheme"],
                ]
            ) { args in
                var request = try buildRequest(from: args)
                if request.destination == nil {
                    // Default to the booted simulator, or a sensible available one.
                    if let sim = try? await XcodeTools.resolveSimulator(nil) {
                        request.destination = "platform=iOS Simulator,id=\(sim.udid)"
                    }
                }
                // Always keep the result bundle: attachments/screenshots can
                // then be pulled out with xcresult_attachments.
                let resultBundle = NSTemporaryDirectory() + "iphone-mirror-test-\(UUID().uuidString).xcresult"
                request.resultBundlePath = resultBundle
                let outcome = try await XcodeTools.test(request, onlyTesting: try args.stringArray("only_testing"))
                var text = outcome.description
                if FileManager.default.fileExists(atPath: resultBundle) {
                    text += "\nResult bundle: \(resultBundle) (use xcresult_attachments to export screenshots/attachments)"
                }
                return textResult(text)
            },

            RegisteredTool(
                name: "devices",
                description: "List paired physical iOS devices (devicectl) and available simulators (simctl), with names, udids, OS versions, and states.",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                // Each half independently: a devicectl failure must not cost
                // the caller the simulator list, or vice versa.
                var physicalText: String
                do { physicalText = DevicectlDeviceList.describe(try await XcodeTools.physicalDevices()) }
                catch { physicalText = "devicectl failed: \(error)" }
                var simulatorText: String
                do { simulatorText = (try await XcodeTools.simulators()).describe() }
                catch { simulatorText = "simctl failed: \(error)" }
                return textResult("PHYSICAL DEVICES\n\(physicalText)\n\nSIMULATORS\n\(simulatorText)")
            },

            RegisteredTool(
                name: "device_install",
                description: "Install a built .app bundle on a paired physical device via devicectl.",
                schema: [
                    "type": "object",
                    "properties": [
                        "app_path": ["type": "string", "description": "Path to the .app bundle (device build, not simulator)"],
                        "device": ["type": "string", "description": "Device name or udid (default: first paired iPhone)"],
                    ],
                    "required": ["app_path"],
                ]
            ) { args in
                let (identifier, name) = try await XcodeTools.resolveDevice(try args.optionalString("device"))
                _ = try await XcodeTools.deviceInstall(device: identifier, appPath: try args.string("app_path"))
                return textResult("Installed on \(name).")
            },

            RegisteredTool(
                name: "device_launch",
                description: "Launch an app by bundle id on a paired physical device. Optional console_seconds attaches the console and captures the app's output for that long (the app keeps running afterwards). After launching, drive the app with the mirroring tools.",
                schema: [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App bundle identifier, e.g. com.example.MyApp"],
                        "device": ["type": "string", "description": "Device name or udid (default: first paired iPhone)"],
                        "terminate_existing": ["type": "boolean", "description": "Kill a running instance first (default true)"],
                        "console_seconds": ["type": "number", "description": "Capture stdout/stderr for N seconds (default 0 = don't attach; capped at 300)"],
                    ],
                    "required": ["bundle_id"],
                ]
            ) { args in
                let (identifier, name) = try await XcodeTools.resolveDevice(try args.optionalString("device"))
                let output = try await XcodeTools.deviceLaunch(
                    device: identifier,
                    bundleID: try args.string("bundle_id"),
                    terminateExisting: try args.bool("terminate_existing", default: true),
                    consoleSeconds: try args.int("console_seconds", default: 0))
                return textResult("Device \(name): \(output)")
            },

            RegisteredTool(
                name: "run_on_iphone",
                description: "THE end-to-end pipeline: build the scheme for the paired iPhone, install it via devicectl, and launch it. The app then appears on the mirrored screen, where the tap/swipe/OCR/screenshot tools can drive it — real-device automated testing without XCUITest.",
                schema: [
                    "type": "object",
                    "properties": [
                        "scheme": ["type": "string", "description": "Xcode scheme to build. Run xcode_list to see the available schemes"],
                        "project_path": ["type": "string", "description": "Path to .xcodeproj/.xcworkspace or project directory (default: current directory)"],
                        "configuration": ["type": "string", "description": "Default Debug"],
                        "device": ["type": "string", "description": "Device name or udid (default: first paired iPhone)"],
                        "timeout_seconds": ["type": "number", "description": "Build timeout, default 900"],
                    ],
                    "required": ["scheme"],
                ]
            ) { args in
                let outcome = try await XcodeTools.buildAndRunOnDevice(
                    projectPath: try args.optionalString("project_path"),
                    scheme: try args.string("scheme"),
                    configuration: try args.optionalString("configuration") ?? "Debug",
                    device: try args.optionalString("device"),
                    timeoutSeconds: try args.int("timeout_seconds", default: 900))
                return textResult("""
                    Built, installed, and launched \(outcome.bundleID) on \(outcome.deviceName).
                    App: \(outcome.appPath)
                    \(outcome.buildDescription)
                    Next: use screenshot / tap / read_screen to drive the app on the mirrored screen.
                    """)
            },

            RegisteredTool(
                name: "run_on_sim",
                description: "Build the scheme for a simulator, boot it if needed, install, and launch — the simulator twin of run_on_iphone. Then drive it with sim_screenshot / sim_openurl (simulator coordinates are separate from the mirroring tools).",
                schema: [
                    "type": "object",
                    "properties": [
                        "scheme": ["type": "string", "description": "Xcode scheme to build. Run xcode_list to see the available schemes"],
                        "project_path": ["type": "string", "description": "Path to .xcodeproj/.xcworkspace or project directory (default: current directory)"],
                        "configuration": ["type": "string", "description": "Default Debug"],
                        "simulator": ["type": "string", "description": "Simulator name or udid (default: the booted one, else the first available iPhone)"],
                        "timeout_seconds": ["type": "number", "description": "Build timeout, default 900"],
                    ],
                    "required": ["scheme"],
                ]
            ) { args in
                let outcome = try await XcodeTools.buildAndRunOnSimulator(
                    projectPath: try args.optionalString("project_path"),
                    scheme: try args.string("scheme"),
                    configuration: try args.optionalString("configuration") ?? "Debug",
                    simulator: try args.optionalString("simulator"),
                    timeoutSeconds: try args.int("timeout_seconds", default: 900))
                return textResult("""
                    Built, installed, and launched \(outcome.bundleID) on simulator \(outcome.deviceName).
                    App: \(outcome.appPath)
                    \(outcome.buildDescription)
                    Next: sim_screenshot to see it, sim_log for its output.
                    """)
            },

            RegisteredTool(
                name: "sim_log",
                description: "Read a simulator's recent unified log (default: the booted one) — the app's os_log/print output. Filter by process name (recommended: the app's name) and/or a custom NSPredicate.",
                schema: [
                    "type": "object",
                    "properties": [
                        "simulator": ["type": "string", "description": "Name or udid (default: booted)"],
                        "last": ["type": "string", "description": "How far back, e.g. \"2m\", \"30s\", \"1h\" (default 2m)"],
                        "process": ["type": "string", "description": "Only entries from this process name"],
                        "predicate": ["type": "string", "description": "Additional NSPredicate, e.g. eventMessage contains \"error\""],
                    ],
                ]
            ) { args in
                textResult(try await XcodeTools.simLog(
                    simulator: try args.optionalString("simulator"),
                    last: try args.optionalString("last") ?? "2m",
                    process: try args.optionalString("process"),
                    predicate: try args.optionalString("predicate")))
            },

            RegisteredTool(
                name: "xcresult_attachments",
                description: "Export every attachment (failure screenshots, activity attachments, …) from an .xcresult bundle to a directory and list the files. xcode_test's output includes the bundle path.",
                schema: [
                    "type": "object",
                    "properties": [
                        "xcresult_path": ["type": "string", "description": "Path to the .xcresult bundle"],
                        "output_dir": ["type": "string", "description": "Where to export (default: a temp directory)"],
                    ],
                    "required": ["xcresult_path"],
                ]
            ) { args in
                let (dir, files) = try await XcodeTools.exportAttachments(
                    xcresultPath: try args.string("xcresult_path"),
                    outputDir: try args.optionalString("output_dir"))
                guard !files.isEmpty else {
                    return textResult("No attachments in the bundle (exported to \(dir)).")
                }
                return textResult("Exported \(files.count) attachment(s) to \(dir):\n" + files.joined(separator: "\n"))
            },

            RegisteredTool(
                name: "sim_boot",
                description: "Boot a simulator (and open the Simulator app so it is visible).",
                schema: [
                    "type": "object",
                    "properties": ["simulator": ["type": "string", "description": "Simulator name or udid"]],
                    "required": ["simulator"],
                ]
            ) { args in
                let (udid, name) = try await resolveAnySimulator(try args.string("simulator"))
                do {
                    _ = try await XcodeTools.simctl(["boot", udid])
                } catch let error as MirrorError where error.message.contains("state: Booted") {
                    // Already booted — that is the goal state, not a failure.
                }
                _ = try await ProcessRunner.run("/usr/bin/open", ["-a", "Simulator"], timeout: 30)
                return textResult("Booted \(name) (\(udid)).")
            },

            RegisteredTool(
                name: "sim_install",
                description: "Install a simulator-built .app on a simulator (default: the booted one).",
                schema: [
                    "type": "object",
                    "properties": [
                        "app_path": ["type": "string", "description": "Path to the built .app bundle"],
                        "simulator": ["type": "string", "description": "Name or udid (default: booted)"],
                    ],
                    "required": ["app_path"],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                _ = try await XcodeTools.simctl(["install", udid, try args.string("app_path")])
                return textResult("Installed on \(name).")
            },

            RegisteredTool(
                name: "sim_launch",
                description: "Launch an app by bundle id on a simulator (default: the booted one). Optional console_seconds captures the app's output.",
                schema: [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App bundle identifier, e.g. com.example.MyApp"],
                        "simulator": ["type": "string", "description": "Name or udid (default: booted)"],
                        "console_seconds": ["type": "number", "description": "Capture output for N seconds (default 0; capped at 300)"],
                    ],
                    "required": ["bundle_id"],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                let consoleSeconds = try args.int("console_seconds", default: 0)
                if consoleSeconds > 0 {
                    let result = try await ProcessRunner.run(
                        "/usr/bin/xcrun",
                        ["simctl", "launch", "--console-pty", udid, try args.string("bundle_id")],
                        timeout: TimeInterval(min(consoleSeconds, 300)))
                    // A timeout is the expected way to detach from a live
                    // console; a real non-zero exit is a launch failure.
                    if !result.timedOut && result.exitCode != 0 {
                        throw MirrorError("simctl launch failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
                    }
                    return textResult("Launched on \(name); console:\n\(result.stdout)")
                }
                let output = try await XcodeTools.simctl(["launch", udid, try args.string("bundle_id")])
                return textResult("Launched on \(name): \(output)")
            },

            RegisteredTool(
                name: "sim_terminate",
                description: "Terminate a running app on a simulator (default: the booted one).",
                schema: [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App bundle identifier, e.g. com.example.MyApp"],
                        "simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"],
                    ],
                    "required": ["bundle_id"],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                _ = try await XcodeTools.simctl(["terminate", udid, try args.string("bundle_id")])
                return textResult("Terminated on \(name).")
            },

            RegisteredTool(
                name: "sim_screenshot",
                description: "Screenshot a simulator's screen (default: the booted one). Note: simulator coordinates are separate from the iPhone-mirroring coordinate space.",
                schema: [
                    "type": "object",
                    "properties": ["simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"]],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                let path = NSTemporaryDirectory() + "sim-screenshot-\(UUID().uuidString).png"
                defer { try? FileManager.default.removeItem(atPath: path) }
                _ = try await XcodeTools.simctl(["io", udid, "screenshot", path])
                guard let data = FileManager.default.contents(atPath: path) else {
                    throw MirrorError("simctl produced no screenshot file.")
                }
                return imageResult(pngData: data, caption: "Simulator \(name) screen.")
            },

            RegisteredTool(
                name: "sim_openurl",
                description: "Open a URL (including deep links / universal links) on a simulator (default: the booted one).",
                schema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "URL to open, including scheme (https://… or a custom deep link)"],
                        "simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"],
                    ],
                    "required": ["url"],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                _ = try await XcodeTools.simctl(["openurl", udid, try args.string("url")])
                return textResult("Opened URL on \(name).")
            },

            RegisteredTool(
                name: "sim_push",
                description: "Deliver a push notification to an app on a simulator (default: the booted one). payload is the APNs JSON — it must contain an \"aps\" key, e.g. {\"aps\":{\"alert\":{\"title\":\"Hi\",\"body\":\"There\"},\"badge\":1}}.",
                schema: [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App bundle identifier, e.g. com.example.MyApp"],
                        "payload": ["type": "string", "description": "APNs payload JSON (must contain an aps key)"],
                        "simulator": ["type": "string", "description": "Name or udid (default: booted)"],
                    ],
                    "required": ["bundle_id", "payload"],
                ]
            ) { args in
                let payload = try args.string("payload")
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["aps"] != nil else {
                    throw MirrorError("payload must be valid JSON with a top-level \"aps\" key.")
                }
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                let path = NSTemporaryDirectory() + "sim-push-\(UUID().uuidString).json"
                defer { try? FileManager.default.removeItem(atPath: path) }
                try payload.write(toFile: path, atomically: true, encoding: .utf8)
                _ = try await XcodeTools.simctl(["push", udid, try args.string("bundle_id"), path])
                return textResult("Push delivered to \(name). Take sim_screenshot to see it.")
            },

            RegisteredTool(
                name: "sim_privacy",
                description: "Grant, revoke, or reset a privacy permission for an app on a simulator — test permission flows without tapping dialogs. Services: all, calendar, contacts, contacts-limited, location, location-always, photos, photos-add, media-library, microphone, motion, reminders, siri.",
                schema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "description": "grant, revoke, or reset"],
                        "service": ["type": "string", "description": "Privacy service to change, e.g. photos, camera, microphone, location, contacts, or all"],
                        "bundle_id": ["type": "string", "description": "Required for grant/revoke; optional for reset"],
                        "simulator": ["type": "string", "description": "Name or udid (default: booted)"],
                    ],
                    "required": ["action", "service"],
                ]
            ) { args in
                let action = try args.string("action")
                guard ["grant", "revoke", "reset"].contains(action) else {
                    throw MirrorError("action must be grant, revoke, or reset.")
                }
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                var arguments = ["privacy", udid, action, try args.string("service")]
                if let bundleID = try args.optionalString("bundle_id") { arguments.append(bundleID) }
                _ = try await XcodeTools.simctl(arguments)
                return textResult("Privacy \(action) applied on \(name).")
            },

            RegisteredTool(
                name: "sim_appearance",
                description: "Switch a simulator between light and dark appearance.",
                schema: [
                    "type": "object",
                    "properties": [
                        "appearance": ["type": "string", "description": "light or dark"],
                        "simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"],
                    ],
                    "required": ["appearance"],
                ]
            ) { args in
                let appearance = try args.string("appearance")
                guard ["light", "dark"].contains(appearance) else {
                    throw MirrorError("appearance must be light or dark.")
                }
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                _ = try await XcodeTools.simctl(["ui", udid, "appearance", appearance])
                return textResult("\(name) switched to \(appearance) mode.")
            },

            RegisteredTool(
                name: "sim_location",
                description: "Set (or clear) a simulator's simulated GPS location.",
                schema: [
                    "type": "object",
                    "properties": [
                        "latitude": ["type": "number", "description": "Latitude in decimal degrees"],
                        "longitude": ["type": "number", "description": "Longitude in decimal degrees"],
                        "clear": ["type": "boolean", "description": "Clear the simulated location instead"],
                        "simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"],
                    ],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                if try args.bool("clear", default: false) {
                    _ = try await XcodeTools.simctl(["location", udid, "clear"])
                    return textResult("Cleared simulated location on \(name).")
                }
                guard let lat = try args.optionalDouble("latitude"),
                      let lon = try args.optionalDouble("longitude") else {
                    throw MirrorError("Provide latitude and longitude, or clear=true.")
                }
                _ = try await XcodeTools.simctl(["location", udid, "set", "\(lat),\(lon)"])
                return textResult("\(name) location set to (\(lat), \(lon)).")
            },

            RegisteredTool(
                name: "sim_statusbar",
                description: "Override a simulator's status bar (clean screenshots: 9:41, full battery/signal) or clear the overrides.",
                schema: [
                    "type": "object",
                    "properties": [
                        "time": ["type": "string", "description": "e.g. 9:41"],
                        "battery_level": ["type": "number", "description": "0-100"],
                        "battery_state": ["type": "string", "description": "charged, charging, or discharging"],
                        "wifi_bars": ["type": "number", "description": "0-3"],
                        "cellular_bars": ["type": "number", "description": "0-4"],
                        "clear": ["type": "boolean", "description": "Remove all overrides"],
                        "simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"],
                    ],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                if try args.bool("clear", default: false) {
                    _ = try await XcodeTools.simctl(["status_bar", udid, "clear"])
                    return textResult("Status bar overrides cleared on \(name).")
                }
                var arguments = ["status_bar", udid, "override"]
                if let time = try args.optionalString("time") { arguments += ["--time", time] }
                if let battery = try args.optionalInt("battery_level") { arguments += ["--batteryLevel", String(battery)] }
                if let state = try args.optionalString("battery_state") { arguments += ["--batteryState", state] }
                if let wifi = try args.optionalInt("wifi_bars") { arguments += ["--wifiBars", String(wifi)] }
                if let cellular = try args.optionalInt("cellular_bars") { arguments += ["--cellularBars", String(cellular)] }
                guard arguments.count > 3 else {
                    throw MirrorError("Provide at least one override (time, battery_level, …) or clear=true.")
                }
                _ = try await XcodeTools.simctl(arguments)
                return textResult("Status bar overridden on \(name).")
            },

            RegisteredTool(
                name: "sim_addmedia",
                description: "Add photos/videos (file paths) to a simulator's Photos library.",
                schema: [
                    "type": "object",
                    "properties": [
                        "paths": ["type": "array", "items": ["type": "string"], "description": "Image/video file paths"],
                        "simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"],
                    ],
                    "required": ["paths"],
                ]
            ) { args in
                let paths = try args.stringArray("paths")
                guard !paths.isEmpty else { throw MirrorError("paths is empty.") }
                for path in paths where !FileManager.default.fileExists(atPath: path) {
                    throw MirrorError("No file at \(path).")
                }
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                _ = try await XcodeTools.simctl(["addmedia", udid] + paths)
                return textResult("Added \(paths.count) media file(s) to \(name)'s Photos library.")
            },

            RegisteredTool(
                name: "sim_uninstall",
                description: "Uninstall an app from a simulator (default: the booted one).",
                schema: [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App bundle identifier, e.g. com.example.MyApp"],
                        "simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"],
                    ],
                    "required": ["bundle_id"],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                _ = try await XcodeTools.simctl(["uninstall", udid, try args.string("bundle_id")])
                return textResult("Uninstalled from \(name).")
            },

            RegisteredTool(
                name: "sim_erase",
                description: "DESTRUCTIVE: factory-reset a simulator — erases all its apps, data, and settings. The simulator is shut down first if booted. Requires the simulator to be named explicitly.",
                schema: [
                    "type": "object",
                    "properties": [
                        "simulator": ["type": "string", "description": "Name or udid — required, to prevent erasing the wrong one"],
                    ],
                    "required": ["simulator"],
                ]
            ) { args in
                let (udid, name) = try await resolveAnySimulator(try args.string("simulator"))
                _ = try? await XcodeTools.simctl(["shutdown", udid])
                _ = try await XcodeTools.simctl(["erase", udid], timeout: 180)
                return textResult("Erased \(name) to factory state.")
            },

            RegisteredTool(
                name: "sim_apps",
                description: "List the apps installed on a simulator (default: the booted one) with bundle ids.",
                schema: [
                    "type": "object",
                    "properties": ["simulator": ["type": "string", "description": "Simulator UDID or name (e.g. \"iPhone 16 Pro\"). Defaults to the booted simulator"]],
                ]
            ) { args in
                let (udid, name) = try await XcodeTools.resolveSimulator(try args.optionalString("simulator"))
                let output = try await XcodeTools.simctl(["listapps", udid])
                let trimmed = output.count > 12_000 ? String(output.prefix(12_000)) + "\n…(truncated)" : output
                return textResult("Apps on \(name):\n\(trimmed)")
            },

            RegisteredTool(
                name: "device_info",
                description: "Detailed info for a paired physical device: OS build, battery, storage, model, lock state.",
                schema: [
                    "type": "object",
                    "properties": ["device": ["type": "string", "description": "Device name or udid (default: first paired iPhone)"]],
                ]
            ) { args in
                let (identifier, name) = try await XcodeTools.resolveDevice(try args.optionalString("device"))
                let output = try await XcodeTools.devicectlText(["device", "info", "details", "--device", identifier])
                return textResult("Device \(name):\n\(output)")
            },

            RegisteredTool(
                name: "device_apps",
                description: "List the apps installed on a paired physical device with bundle ids.",
                schema: [
                    "type": "object",
                    "properties": ["device": ["type": "string", "description": "Device name or udid (default: first paired iPhone)"]],
                ]
            ) { args in
                let (identifier, name) = try await XcodeTools.resolveDevice(try args.optionalString("device"))
                let output = try await XcodeTools.devicectlText(["device", "info", "apps", "--device", identifier])
                return textResult("Apps on \(name):\n\(output)")
            },

            RegisteredTool(
                name: "device_uninstall",
                description: "Uninstall an app from a paired physical device by bundle id.",
                schema: [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App bundle identifier, e.g. com.example.MyApp"],
                        "device": ["type": "string", "description": "Device name or udid (default: first paired iPhone)"],
                    ],
                    "required": ["bundle_id"],
                ]
            ) { args in
                let (identifier, name) = try await XcodeTools.resolveDevice(try args.optionalString("device"))
                _ = try await XcodeTools.devicectlText(
                    ["device", "uninstall", "app", "--device", identifier, try args.string("bundle_id")])
                return textResult("Uninstalled \(try args.string("bundle_id")) from \(name).")
            },
        ]
    }

    static func buildRequest(from args: ToolArgs) throws -> XcodeTools.BuildRequest {
        XcodeTools.BuildRequest(
            projectPath: try args.optionalString("project_path"),
            scheme: try args.string("scheme"),
            configuration: try args.optionalString("configuration"),
            destination: try args.optionalString("destination"),
            extraArguments: try args.stringArray("extra_args"),
            timeoutSeconds: try args.int("timeout_seconds", default: 900)
        )
    }

    /// Like XcodeTools.resolveSimulator but does not require it to be booted.
    static func resolveAnySimulator(_ query: String) async throws -> (udid: String, name: String) {
        let list = try await XcodeTools.simulators()
        let all = list.devices.values.flatMap { $0 }.filter { $0.isAvailable ?? false }
        let lowered = query.lowercased()
        guard let match = all.first(where: {
            $0.udid?.lowercased() == lowered || $0.name?.lowercased() == lowered
        }), let udid = match.udid else {
            throw MirrorError("No available simulator matched \"\(query)\". Use the devices tool to list them.")
        }
        return (udid, match.name ?? udid)
    }
}
