import Foundation
import MCP
import MirrorCore

/// Tools that drive the mirrored iPhone through the iPhone Mirroring app.
enum MirroringTools {
    static let coordinateNote = "Coordinates are pixel positions in the most recent screenshot (origin top-left)."

    static func all(session: MirrorSession) -> [RegisteredTool] {
        let xyProperties: [String: Value] = [
            "x": ["type": "number", "description": "X pixel coordinate in the last screenshot"],
            "y": ["type": "number", "description": "Y pixel coordinate in the last screenshot"],
        ]
        let swipeProperties: [String: Value] = [
            "from_x": ["type": "number"], "from_y": ["type": "number"],
            "to_x": ["type": "number"], "to_y": ["type": "number"],
            "duration_ms": ["type": "number", "description": "Gesture duration in ms"],
        ]

        return [
            RegisteredTool(
                name: "status",
                description: "Report the iPhone Mirroring session state (connected/paused/not running), window geometry, device orientation, and whether the Accessibility and Screen Recording permissions are granted. Call this first when anything misbehaves.",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                let status = await session.status()
                var lines = ["Session: \(status.state.rawValue)"]
                if let bounds = status.windowBounds {
                    lines.append("Window: origin=(\(Int(bounds.origin.x)), \(Int(bounds.origin.y))) size=\(Int(bounds.width))x\(Int(bounds.height)) points")
                }
                if let orientation = status.orientation { lines.append("Orientation: \(orientation)") }
                if let size = status.lastScreenshotPixelSize {
                    lines.append("Coordinate space: \(Int(size.width))x\(Int(size.height)) pixels (last screenshot)")
                }
                lines.append(status.permissions.description)
                return textResult(lines.joined(separator: "\n"))
            },

            RegisteredTool(
                name: "mirror_launch",
                description: "Launch (or focus) the built-in iPhone Mirroring app and wait for its window. Use when status reports notRunning or noWindow.",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                let status = try await session.launchMirroring()
                return textResult("iPhone Mirroring is running. Session: \(status.state.rawValue). Take a screenshot to see the phone screen.")
            },

            RegisteredTool(
                name: "screenshot",
                description: "Capture the mirrored iPhone screen as a PNG. \(coordinateNote) By default the image is returned at full capture resolution so what you see IS the coordinate space. Optional max_width downscales the returned image to save tokens — coordinates must then be scaled back to full resolution (the caption tells you the factor).",
                schema: [
                    "type": "object",
                    "properties": [
                        "max_width": ["type": "number", "description": "Optional: cap the returned image width in pixels (coordinates stay full-resolution)"],
                    ],
                ]
            ) { args in
                let maxWidth = try args.optionalInt("max_width")
                let shot = try await session.screenshot(maxWidth: maxWidth)
                var caption = "iPhone screen \(shot.pixelWidth)x\(shot.pixelHeight) px. \(coordinateNote)"
                if shot.coordinateScale != 1.0 {
                    caption += " Image shown downscaled ×\(String(format: "%.2f", shot.coordinateScale)): multiply coordinates you read off this image by that factor before tapping."
                }
                return imageResult(pngData: shot.pngData, caption: caption)
            },

            RegisteredTool(
                name: "tap",
                description: "Tap the iPhone screen. \(coordinateNote) Pass expect to VERIFY the tap: the call fails unless that text appears afterwards — strongly recommended, silent misses are this transport's main failure mode.",
                schema: [
                    "type": "object",
                    "properties": .object(xyProperties.merging([
                        "expect": ["type": "string", "description": "Text that must appear on screen after the tap (verified via OCR polling)"],
                        "expect_timeout_seconds": ["type": "number", "description": "How long to wait for expect (default 10)"],
                    ]) { a, _ in a }),
                    "required": ["x", "y"],
                ]
            ) { args in
                let expect = try args.optionalString("expect")
                try await session.tap(
                    x: try args.double("x"), y: try args.double("y"),
                    expect: expect,
                    expectTimeout: try args.optionalDouble("expect_timeout_seconds") ?? 10)
                if let expect {
                    return textResult("Tapped (\(Int(try args.double("x"))), \(Int(try args.double("y")))) — verified: \"\(expect)\" is on screen.")
                }
                return textResult("Tapped (\(Int(try args.double("x"))), \(Int(try args.double("y")))). Take a screenshot to verify the result.")
            },

            RegisteredTool(
                name: "double_tap",
                description: "Double-tap the iPhone screen (zoom, text selection). \(coordinateNote)",
                schema: ["type": "object", "properties": .object(xyProperties), "required": ["x", "y"]]
            ) { args in
                try await session.doubleTap(x: try args.double("x"), y: try args.double("y"))
                return textResult("Double-tapped.")
            },

            RegisteredTool(
                name: "long_press",
                description: "Long-press the iPhone screen (context menus, app-icon menus). \(coordinateNote)",
                schema: [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"], "y": ["type": "number"],
                        "duration_ms": ["type": "number", "description": "Hold duration, default 600"],
                    ],
                    "required": ["x", "y"],
                ]
            ) { args in
                try await session.longPress(
                    x: try args.double("x"), y: try args.double("y"),
                    durationMs: try args.int("duration_ms", default: 600))
                return textResult("Long-pressed.")
            },

            RegisteredTool(
                name: "swipe",
                description: "Swipe/scroll with a trackpad-style gesture — content follows the finger (swipe up = scroll down the page). Fast swipes flick with momentum. Use drag instead for moving icons or sliders. \(coordinateNote)",
                schema: ["type": "object", "properties": .object(swipeProperties), "required": ["from_x", "from_y", "to_x", "to_y"]]
            ) { args in
                try await session.swipe(
                    fromX: try args.double("from_x"), fromY: try args.double("from_y"),
                    toX: try args.double("to_x"), toY: try args.double("to_y"),
                    durationMs: try args.int("duration_ms", default: 300))
                return textResult("Swiped.")
            },

            RegisteredTool(
                name: "drag",
                description: "Sustained press-and-drag (rearrange icons, sliders, drag-and-drop) — distinct from swipe, which scrolls. \(coordinateNote)",
                schema: ["type": "object", "properties": .object(swipeProperties), "required": ["from_x", "from_y", "to_x", "to_y"]]
            ) { args in
                try await session.drag(
                    fromX: try args.double("from_x"), fromY: try args.double("from_y"),
                    toX: try args.double("to_x"), toY: try args.double("to_y"),
                    durationMs: try args.int("duration_ms", default: 1000))
                return textResult("Dragged.")
            },

            RegisteredTool(
                name: "type_text",
                description: "Type text on the mirrored iPhone via keystrokes (a text field must be focused — tap it first). ASCII only; characters like emoji/CJK/accents are skipped and reported. Set submit=true to press Return afterwards.",
                schema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "submit": ["type": "boolean", "description": "Press Return after typing (default false)"],
                    ],
                    "required": ["text"],
                ]
            ) { args in
                let skipped = try await session.typeText(
                    try args.string("text"), submit: try args.bool("submit", default: false))
                if skipped.isEmpty { return textResult("Typed.") }
                return textResult("Typed, but skipped characters with no key mapping: \(skipped)")
            },

            RegisteredTool(
                name: "press_key",
                description: "Press a single key or shortcut on the mirrored iPhone, e.g. \"return\", \"escape\", \"delete\", \"up\"/\"down\"/\"left\"/\"right\", \"cmd+a\", \"cmd+l\". Note: most app-level Mac shortcuts do not pass through mirroring; navigation keys and text-editing shortcuts do.",
                schema: [
                    "type": "object",
                    "properties": ["key": ["type": "string", "description": "Key spec like \"return\" or \"cmd+a\""]],
                    "required": ["key"],
                ]
            ) { args in
                try await session.pressKey(spec: try args.string("key"))
                return textResult("Pressed \(try args.string("key")).")
            },

            RegisteredTool(
                name: "home",
                description: "Go to the iPhone Home Screen (View menu / ⌘1).",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                try await session.home()
                return textResult("Home Screen.")
            },

            RegisteredTool(
                name: "app_switcher",
                description: "Open the iPhone App Switcher (View menu / ⌘2). From here you can swipe an app card up (drag upward) to force-quit it.",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                try await session.appSwitcher()
                return textResult("App Switcher opened. Take a screenshot to see app cards.")
            },

            RegisteredTool(
                name: "spotlight",
                description: "Open iPhone Spotlight search (View menu / ⌘3).",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                try await session.spotlight()
                return textResult("Spotlight opened.")
            },

            RegisteredTool(
                name: "launch_app",
                description: "Launch an iPhone app by name: opens Spotlight, types the name, presses Return to launch the top hit. Verify with a screenshot — Spotlight's top hit can differ from the intent.",
                schema: [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "App name as it appears on the phone"]],
                    "required": ["name"],
                ]
            ) { args in
                let name = try args.string("name")
                try await session.launchApp(named: name)
                return textResult("Launched \"\(name)\" via Spotlight. Take a screenshot to confirm the right app opened.")
            },

            RegisteredTool(
                name: "open_url",
                description: "Open a URL on the iPhone: launches Safari via Spotlight, focuses the address bar (⌘L), types the URL, presses Return.",
                schema: [
                    "type": "object",
                    "properties": ["url": ["type": "string"]],
                    "required": ["url"],
                ]
            ) { args in
                let url = try args.string("url")
                try await session.openURL(url)
                return textResult("Navigating Safari to \(url). Take a screenshot to confirm.")
            },

            RegisteredTool(
                name: "shake",
                description: "Trigger the iOS shake gesture (⌃⌘Z) — undo dialogs, developer menus (e.g. React Native).",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                try await session.shake()
                return textResult("Shake sent.")
            },

            RegisteredTool(
                name: "read_screen",
                description: "OCR the current iPhone screen and list every recognized text element with its center (directly tappable) and bounding box in screenshot pixel coordinates. Cheaper than a screenshot for text-heavy screens.",
                schema: [
                    "type": "object",
                    "properties": ["fast": ["type": "boolean", "description": "Faster, less accurate recognition (default false)"]],
                ]
            ) { args in
                let elements = try await session.readScreen(fast: try args.bool("fast", default: false))
                return textResult(describeElements(elements))
            },

            RegisteredTool(
                name: "find_text",
                description: "Find on-screen text matching a query (exact match ranks first, then prefix, then substring; case-insensitive). Returns matches with tappable centers.",
                schema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "exact": ["type": "boolean", "description": "Only exact (case-insensitive) matches"],
                    ],
                    "required": ["query"],
                ]
            ) { args in
                let matches = try await session.findText(
                    try args.string("query"), exact: try args.bool("exact", default: false))
                return textResult(describeElements(matches))
            },

            RegisteredTool(
                name: "tap_text",
                description: "OCR-locate text on screen and tap its center. Best-match first; pass index to pick a later match. Pass expect to VERIFY the tap: the call fails unless that text appears afterwards — strongly recommended.",
                schema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "index": ["type": "number", "description": "Which match to tap (0-based, default 0)"],
                        "exact": ["type": "boolean"],
                        "expect": ["type": "string", "description": "Text that must appear on screen after the tap (verified via OCR polling)"],
                        "expect_timeout_seconds": ["type": "number", "description": "How long to wait for expect (default 10)"],
                    ],
                    "required": ["query"],
                ]
            ) { args in
                let expect = try args.optionalString("expect")
                let element = try await session.tapText(
                    try args.string("query"),
                    index: try args.int("index", default: 0),
                    exact: try args.bool("exact", default: false),
                    expect: expect,
                    expectTimeout: try args.optionalDouble("expect_timeout_seconds") ?? 10)
                let verified = expect.map { " — verified: \"\($0)\" is on screen" } ?? ""
                return textResult("Tapped \"\(element.text)\" at (\(Int(element.center.x)), \(Int(element.center.y)))\(verified).")
            },

            RegisteredTool(
                name: "wait_for_text",
                description: "Poll the screen (OCR) until the given text appears — for loading screens, transitions, async UI. Fails after the timeout.",
                schema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "timeout_seconds": ["type": "number", "description": "Default 15, max 120"],
                        "exact": ["type": "boolean"],
                    ],
                    "required": ["text"],
                ]
            ) { args in
                let elapsed = try await session.waitForText(
                    try args.string("text"),
                    timeoutSeconds: try args.optionalDouble("timeout_seconds") ?? 15,
                    exact: try args.bool("exact", default: false))
                return textResult("Text appeared after \(String(format: "%.1f", elapsed))s.")
            },

            RegisteredTool(
                name: "scroll_to",
                description: "Swipe repeatedly (direction = finger direction; \"up\" scrolls down the page) until the given text becomes visible, then report its tappable center.",
                schema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "direction": ["type": "string", "description": "up (default), down, left, right"],
                        "max_swipes": ["type": "number", "description": "Default 8, max 20"],
                    ],
                    "required": ["text"],
                ]
            ) { args in
                let element = try await session.scrollTo(
                    try args.string("text"),
                    direction: try args.optionalString("direction") ?? "up",
                    maxSwipes: try args.int("max_swipes", default: 8))
                return textResult("Found \"\(element.text)\" at center (\(Int(element.center.x)), \(Int(element.center.y))). It is now visible.")
            },

            RegisteredTool(
                name: "record_screen",
                description: "Record the mirrored iPhone screen to a .mov file for a fixed duration and return the file path. The window must stay visible while recording.",
                schema: [
                    "type": "object",
                    "properties": [
                        "seconds": ["type": "number", "description": "Duration, 1-600"],
                        "output_path": ["type": "string", "description": "Optional .mov output path"],
                    ],
                    "required": ["seconds"],
                ]
            ) { args in
                let path = try await session.record(
                    seconds: try args.int("seconds"),
                    outputPath: try args.optionalString("output_path"))
                return textResult("Recording saved to \(path)")
            },

            RegisteredTool(
                name: "paste_text",
                description: "Paste text into the focused phone text field via the bridged clipboard (⌘V) — full fidelity (emoji/CJK/accents survive) and instant for long strings, unlike type_text's ASCII keystrokes. The user's Mac clipboard is saved and restored. A text field must be focused (tap it first). Set submit=true to press Return afterwards.",
                schema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "submit": ["type": "boolean", "description": "Press Return after pasting (default false)"],
                    ],
                    "required": ["text"],
                ]
            ) { args in
                try await session.pasteText(
                    try args.string("text"), submit: try args.bool("submit", default: false))
                return textResult("Pasted. Take a screenshot to verify the field contents.")
            },

            RegisteredTool(
                name: "read_clipboard",
                description: "Read the clipboard as text. With copy_first=true (default), presses ⌘C on the phone first, copying the current selection through the bridged clipboard — the way to extract exact text from the phone without OCR. Select the text on the phone first (long_press + drag handles, or tap a text field and cmd+a via press_key).",
                schema: [
                    "type": "object",
                    "properties": [
                        "copy_first": ["type": "boolean", "description": "Press ⌘C on the phone before reading (default true)"],
                    ],
                ]
            ) { args in
                let text = try await session.copyAndReadClipboard(
                    pressCopy: try args.bool("copy_first", default: true))
                guard let text, !text.isEmpty else {
                    return textResult("Clipboard has no text. Make sure something was selected on the phone (or pass copy_first=false to read the Mac clipboard as-is).")
                }
                return textResult("Clipboard text:\n\(text)")
            },

            RegisteredTool(
                name: "mirror_restart",
                description: "Fully restart the iPhone Mirroring app: quit, relaunch, resume. THE recovery for a zombie session — video updates but every tap/key is silently ignored. Also useful when the session is wedged in any other way.",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                let status = try await session.restartMirroring()
                return textResult("iPhone Mirroring restarted. Session: \(status.state.rawValue). Take a screenshot to confirm the phone screen is live.")
            },

            RegisteredTool(
                name: "doctor",
                description: "Non-destructive end-to-end self-test: all four permissions (Accessibility, Screen Recording, post-event access, Automation/System Events), session + window state, a capture round-trip, and an input-delivery probe (marches the cursor and verifies events actually moved it — no clicks posted). Run this first when input or capture misbehaves.",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                textResult(await session.doctor().describe())
            },

            RegisteredTool(
                name: "record_start",
                description: "Start a DETACHED screen recording of the mirrored iPhone — tap/swipe/type tools keep working while it runs. Stop with record_stop to get the .mov. The mirroring window must stay visible on screen for the whole recording (input tools keep it frontmost automatically).",
                schema: [
                    "type": "object",
                    "properties": ["output_path": ["type": "string", "description": "Optional .mov output path"]],
                ]
            ) { args in
                let path = try await session.startRecording(outputPath: try args.optionalString("output_path"))
                return textResult("Recording started → \(path). Drive the phone, then call record_stop.")
            },

            RegisteredTool(
                name: "record_stop",
                description: "Stop the detached recording started by record_start and return the finalized .mov path.",
                schema: ["type": "object", "properties": [:]]
            ) { _ in
                let path = try await session.stopRecording()
                return textResult("Recording saved to \(path)")
            },

            RegisteredTool(
                name: "wait_for_screen_change",
                description: "Poll until the screen visually CHANGES (mode \"changed\") or STOPS changing (mode \"stable\", e.g. an animation finished) using a perceptual frame diff — complements wait_for_text for imagery OCR cannot read. Returns the elapsed time.",
                schema: [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "description": "\"changed\" (default) or \"stable\""],
                        "timeout_seconds": ["type": "number", "description": "Default 15, max 120"],
                        "threshold": ["type": "number", "description": "Normalized difference 0-1 that counts as a change (default 0.02)"],
                    ],
                ]
            ) { args in
                let elapsed = try await session.waitForScreenChange(
                    mode: try args.optionalString("mode") ?? "changed",
                    timeoutSeconds: try args.optionalDouble("timeout_seconds") ?? 15,
                    threshold: try args.optionalDouble("threshold") ?? 0.02)
                return textResult("Screen \(try args.optionalString("mode") ?? "changed") after \(String(format: "%.1f", elapsed))s.")
            },

            RegisteredTool(
                name: "annotated_screenshot",
                description: "Screenshot with every OCR text element boxed and numbered, plus a legend of index → text/center. One call to see exactly where the tappable coordinates are. \(coordinateNote)",
                schema: [
                    "type": "object",
                    "properties": [
                        "max_width": ["type": "number", "description": "Optional: cap the returned image width in pixels (coordinates stay full-resolution)"],
                    ],
                ]
            ) { args in
                let (shot, elements) = try await session.annotatedScreenshot(
                    maxWidth: try args.optionalInt("max_width"))
                var caption = "iPhone screen \(shot.pixelWidth)x\(shot.pixelHeight) px with \(elements.count) OCR elements boxed. \(coordinateNote)"
                if shot.coordinateScale != 1.0 {
                    caption += " Image downscaled ×\(String(format: "%.2f", shot.coordinateScale))."
                }
                if !elements.isEmpty {
                    caption += "\nLegend:\n" + elements.enumerated().map { index, element in
                        "\(index): \"\(element.text)\" center=(\(Int(element.center.x)), \(Int(element.center.y)))"
                    }.joined(separator: "\n")
                }
                return imageResult(pngData: shot.pngData, caption: caption)
            },

            RegisteredTool(
                name: "batch",
                description: "Run several input steps in ONE call — far faster than separate tool calls for scripted flows. Steps run in order; the first failure stops the batch and reports the step index. Step tools: tap, double_tap, long_press, swipe, drag, type_text, paste_text, press_key, tap_text, wait_for_text, home, app_switcher, spotlight, launch_app, open_url, sleep_ms. Each step: {\"tool\": name, \"args\": {…}} with the same args as the standalone tool.",
                schema: [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "tool": ["type": "string"],
                                    "args": ["type": "object"],
                                ],
                                "required": ["tool"],
                            ],
                        ],
                    ],
                    "required": ["steps"],
                ]
            ) { args in
                let steps = try args.objectArray("steps")
                guard !steps.isEmpty else { throw MirrorError("The batch has no steps.") }
                guard steps.count <= 30 else { throw MirrorError("Too many steps (\(steps.count)); max 30 per batch.") }
                var results: [String] = []
                for (index, rawStep) in steps.enumerated() {
                    let step = ToolArgs(rawStep)
                    let name = try step.string("tool")
                    let stepArgs = ToolArgs(rawStep["args"]?.objectValue ?? [:])
                    do {
                        results.append("\(index + 1). \(name): \(try await runBatchStep(name, stepArgs, session: session))")
                    } catch {
                        let message = (error as? MirrorError)?.description ?? "\(error)"
                        results.append("\(index + 1). \(name): FAILED — \(message)")
                        results.append("Batch stopped at step \(index + 1) of \(steps.count).")
                        return CallTool.Result(
                            content: [.text(text: results.joined(separator: "\n"), annotations: nil, _meta: nil)],
                            isError: true)
                    }
                }
                return textResult(results.joined(separator: "\n"))
            },
        ]
    }

    /// Dispatch for batch steps — the same session paths as the standalone
    /// tools, without re-entering the tool serializer.
    private static func runBatchStep(
        _ name: String, _ args: ToolArgs, session: MirrorSession
    ) async throws -> String {
        switch name {
        case "tap":
            try await session.tap(
                x: try args.double("x"), y: try args.double("y"),
                expect: try args.optionalString("expect"),
                expectTimeout: try args.optionalDouble("expect_timeout_seconds") ?? 10)
            return "tapped (\(Int(try args.double("x"))), \(Int(try args.double("y"))))"
        case "double_tap":
            try await session.doubleTap(x: try args.double("x"), y: try args.double("y"))
            return "double-tapped"
        case "long_press":
            try await session.longPress(
                x: try args.double("x"), y: try args.double("y"),
                durationMs: try args.int("duration_ms", default: 600))
            return "long-pressed"
        case "swipe":
            try await session.swipe(
                fromX: try args.double("from_x"), fromY: try args.double("from_y"),
                toX: try args.double("to_x"), toY: try args.double("to_y"),
                durationMs: try args.int("duration_ms", default: 300))
            return "swiped"
        case "drag":
            try await session.drag(
                fromX: try args.double("from_x"), fromY: try args.double("from_y"),
                toX: try args.double("to_x"), toY: try args.double("to_y"),
                durationMs: try args.int("duration_ms", default: 1000))
            return "dragged"
        case "type_text":
            let skipped = try await session.typeText(
                try args.string("text"), submit: try args.bool("submit", default: false))
            return skipped.isEmpty ? "typed" : "typed (skipped: \(skipped))"
        case "paste_text":
            try await session.pasteText(
                try args.string("text"), submit: try args.bool("submit", default: false))
            return "pasted"
        case "press_key":
            try await session.pressKey(spec: try args.string("key"))
            return "pressed \(try args.string("key"))"
        case "tap_text":
            let element = try await session.tapText(
                try args.string("query"),
                index: try args.int("index", default: 0),
                exact: try args.bool("exact", default: false),
                expect: try args.optionalString("expect"),
                expectTimeout: try args.optionalDouble("expect_timeout_seconds") ?? 10)
            return "tapped \"\(element.text)\""
        case "wait_for_text":
            let elapsed = try await session.waitForText(
                try args.string("text"),
                timeoutSeconds: try args.optionalDouble("timeout_seconds") ?? 15,
                exact: try args.bool("exact", default: false))
            return "text appeared after \(String(format: "%.1f", elapsed))s"
        case "home":
            try await session.home()
            return "home screen"
        case "app_switcher":
            try await session.appSwitcher()
            return "app switcher"
        case "spotlight":
            try await session.spotlight()
            return "spotlight"
        case "launch_app":
            try await session.launchApp(named: try args.string("name"))
            return "launched \(try args.string("name"))"
        case "open_url":
            try await session.openURL(try args.string("url"))
            return "opened URL"
        case "sleep_ms":
            let ms = min(max(try args.int("ms"), 1), 30_000)
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "slept \(ms)ms"
        default:
            throw MirrorError("Unknown batch step tool \"\(name)\". See the batch tool description for the allowed set.")
        }
    }
}
