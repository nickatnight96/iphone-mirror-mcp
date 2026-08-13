import AppKit
import CoreGraphics
import Foundation

/// Orchestrates all interaction with the mirrored iPhone: capture, pointing,
/// typing, OCR-driven helpers, and system navigation.
///
/// An actor so concurrent MCP tool calls serialize — interleaved synthetic
/// gestures corrupt each other.
///
/// Coordinate contract: every x/y accepted here is a **pixel coordinate in
/// the most recent screenshot**. At input time the window bounds are
/// re-queried, and the pixel is mapped proportionally into the *current*
/// bounds — so a window that moved between screenshot and tap still receives
/// the tap at the right spot on the phone screen.
public actor MirrorSession {
    let bridge = MirrorWindowBridge()

    /// Pixel size of the most recent screenshot; established lazily.
    private var lastImageSize: CGSize?

    // Flow pacing (microseconds), tuned against the mirroring session.
    static let spotlightAppearanceUs: UInt32 = 800_000
    static let searchResultsUs: UInt32 = 1_000_000
    static let safariLoadUs: UInt32 = 1_500_000
    static let addressBarUs: UInt32 = 500_000
    static let preReturnUs: UInt32 = 300_000
    /// Post-resume settle: observed live 2026-08-12 — a successful Resume
    /// click took slightly over 2s to report connected, so 2s declared a
    /// resume failed that had actually worked.
    static let resumeSettleUs: UInt32 = 3_000_000

    public init() {}

    // MARK: - State

    public struct Status: Sendable {
        public let state: MirroringState
        public let windowBounds: CGRect?
        public let orientation: String?
        public let permissions: PermissionStatus
        public let lastScreenshotPixelSize: CGSize?
    }

    public func status() -> Status {
        let info = bridge.windowInfo()
        var orientation: String?
        if let info {
            orientation = info.bounds.height >= info.bounds.width ? "portrait" : "landscape"
        }
        return Status(
            state: bridge.state(),
            windowBounds: info?.bounds,
            orientation: orientation,
            permissions: PermissionStatus.current(),
            lastScreenshotPixelSize: lastImageSize
        )
    }

    public func launchMirroring() async throws -> Status {
        try await bridge.launchApp()
        _ = ensureReady(forInput: false)
        return status()
    }

    // MARK: - Readiness

    /// Ensures the session can be used: app running, window present, session
    /// connected (auto-dismissing pause overlays), and — for input — the
    /// Accessibility permission granted and the window frontmost.
    @discardableResult
    func ensureReady(forInput: Bool) -> MirrorError? {
        switch bridge.state() {
        case .notRunning:
            return MirrorError(
                "iPhone Mirroring is not running.",
                remediation: "Call the mirror_launch tool (or open the iPhone Mirroring app) first.")
        case .noWindow:
            return MirrorError.windowNotFound()
        case .paused:
            attemptResume()
            if bridge.state() != .connected {
                return MirrorError(
                    "The mirroring session is paused and could not be resumed automatically.",
                    remediation: "Make sure the iPhone is locked and not in use, then click Resume in the iPhone Mirroring window.")
            }
        case .connected:
            break
        }
        if forInput {
            guard PermissionStatus.current().accessibility else {
                return MirrorError.accessibilityDenied()
            }
            // Input posted while another app is frontmost is silently
            // dropped by iPhone Mirroring — failing here is the only honest
            // outcome when activation does not take.
            guard bridge.activate() else {
                return MirrorError(
                    "Could not bring the iPhone Mirroring window to the front; input would be silently dropped.",
                    remediation: "Click the iPhone Mirroring window once to focus it. If macOS prompted for the Automation (System Events) permission, grant it to the app hosting this server, then retry.")
            }
        }
        return nil
    }

    /// Tries the AX press first, then a real HID click. AXUIElementPerformAction
    /// can return .success while the overlay ignores the press, so success is
    /// judged ONLY by the session state afterwards — never by the AX return
    /// value.
    private func attemptResume() {
        if bridge.pressResumeButton() {
            usleep(Self.resumeSettleUs)
            if bridge.state() == .connected { return }
        }
        // AX press missing or not honored: real click at the button.
        if let center = bridge.resumeButtonCenter() {
            bridge.activate()
            if !MirrorWindowBridge.systemEventsClick(at: center) {
                try? MirrorInput.tap(at: center)
            }
            usleep(Self.resumeSettleUs)
            if bridge.state() == .connected { return }
        }
        // The overlay often exposes NO AX button at all (observed live: a
        // single bare AXGroup) — but the dismiss control still renders at a
        // predictable spot: the "Resume" variant at the window center, the
        // "iPhone in Use → Connect" variant at ~65% height. Click each in
        // turn, re-checking paused right before every click so a session
        // that resumed on its own doesn't take a stray tap on the live
        // phone screen.
        for clickPoint in Self.pauseOverlayClickPoints(for: bridge.windowInfo()?.bounds) {
            guard bridge.state() == .paused else { return }
            bridge.activate()
            if !MirrorWindowBridge.systemEventsClick(at: clickPoint) {
                try? MirrorInput.tap(at: clickPoint)
            }
            usleep(Self.resumeSettleUs)
            if bridge.state() == .connected { return }
        }
    }

    /// Where to click to dismiss a pause overlay that exposes no AX button:
    /// the Resume button renders at the window center; the "iPhone in Use"
    /// overlay's Connect button renders at ~65% of the window height
    /// (both observed live 2026-08-12/13).
    static func pauseOverlayClickPoints(for bounds: CGRect?) -> [CGPoint] {
        guard let bounds else { return [] }
        return [
            CGPoint(x: bounds.midX, y: bounds.midY),
            CGPoint(x: bounds.midX, y: bounds.origin.y + bounds.height * 0.65),
        ]
    }

    // MARK: - Coordinate mapping

    /// Captures the mirroring window with ONE retry on failure, re-querying
    /// the window fresh for the second attempt. Capture fails transiently
    /// (~occasionally even on a healthy session) when the window is
    /// mid-transition or briefly absent from CGWindowList; a stale
    /// MirrorWindowInfo would make the retry pointless, so each attempt
    /// looks the window up again.
    private func captureCurrentWindow() async throws -> CaptureResult {
        try await withOneRetry(delayNs: 300_000_000) { _ in
            guard let info = bridge.windowInfo() else { throw MirrorError.windowNotFound() }
            return try await MirrorCapture.capture(windowInfo: info)
        }
    }

    /// Current geometry: fresh window bounds + last screenshot pixel size.
    /// Captures a screenshot first when none exists yet (the pixel contract
    /// needs an image size).
    func currentGeometry() async throws -> WindowGeometry {
        guard let info = bridge.windowInfo() else { throw MirrorError.windowNotFound() }
        if lastImageSize == nil {
            let capture = try await captureCurrentWindow()
            lastImageSize = capture.geometry.imagePixelSize
        }
        return WindowGeometry(
            windowID: info.windowID,
            boundsPoints: info.bounds,
            imagePixelSize: lastImageSize!
        )
    }

    // MARK: - Capture

    public struct Screenshot: Sendable {
        public let pngData: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// Scale between the returned (possibly downscaled) image and the
        /// coordinate space tools accept. 1.0 = tap coordinates match image
        /// pixels exactly.
        public let coordinateScale: Double
    }

    /// Captures the mirroring window. `maxWidth` (pixels) downscales the
    /// returned image to save tokens; coordinates remain in FULL-resolution
    /// pixel space, so multiply image coordinates by `coordinateScale` when
    /// the image was downscaled.
    public func screenshot(maxWidth: Int? = nil) async throws -> Screenshot {
        if let error = ensureReady(forInput: false) { throw error }
        let capture = try await captureCurrentWindow()
        lastImageSize = capture.geometry.imagePixelSize

        var image = capture.image
        var scale = 1.0
        if let maxWidth, maxWidth > 0, image.width > maxWidth {
            // downscaled() caps the longest side; convert the width cap into
            // the equivalent longest-side cap so width lands at maxWidth.
            let widthScale = Double(maxWidth) / Double(image.width)
            let longestSideCap = Int((Double(max(image.width, image.height)) * widthScale).rounded())
            let scaled = ImageUtil.downscaled(image, maxDimension: longestSideCap)
            scale = Double(image.width) / Double(scaled.width)
            image = scaled
        }
        return Screenshot(
            pngData: try ImageUtil.pngData(from: image),
            pixelWidth: capture.image.width,
            pixelHeight: capture.image.height,
            coordinateScale: scale
        )
    }

    public func record(seconds: Int, outputPath: String?) async throws -> String {
        if let error = ensureReady(forInput: false) { throw error }
        guard let info = bridge.windowInfo() else { throw MirrorError.windowNotFound() }
        bridge.activate()  // screencapture -R needs the window visible on the active Space
        return try await MirrorCapture.record(windowInfo: info, seconds: seconds, outputPath: outputPath)
    }

    /// The detached recording, when one is running.
    private var recording: (process: Process, path: String)?

    /// Starts a detached recording — input tools keep working while it runs.
    public func startRecording(outputPath: String?) async throws -> String {
        if let current = recording {
            throw MirrorError("A recording is already running (\(current.path)). Call record_stop first.")
        }
        if let error = ensureReady(forInput: false) { throw error }
        guard let info = bridge.windowInfo() else { throw MirrorError.windowNotFound() }
        bridge.activate()  // region capture records whatever is visually there
        let started = try MirrorCapture.startRecordingProcess(windowInfo: info, outputPath: outputPath)
        recording = started
        return started.path
    }

    /// Stops the detached recording and returns the finalized .mov path.
    public func stopRecording() async throws -> String {
        guard let current = recording else {
            throw MirrorError("No recording is running. Call record_start first.")
        }
        recording = nil
        current.process.interrupt()  // screencapture finalizes on SIGINT
        for _ in 0..<20 where current.process.isRunning {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if current.process.isRunning { current.process.terminate() }
        guard FileManager.default.fileExists(atPath: current.path) else {
            throw MirrorError("Recording stopped but produced no file at \(current.path).",
                              remediation: "The window may have moved or the recording was interrupted; retry with record_start.")
        }
        return current.path
    }

    /// Polls until the screen visually changes (mode "changed") or stops
    /// changing (mode "stable"), using a perceptual mean-difference of
    /// downsampled frames. Complements wait_for_text for imagery and
    /// animations OCR cannot see. Returns elapsed seconds.
    public func waitForScreenChange(mode: String, timeoutSeconds: Double, threshold: Double) async throws -> Double {
        if let error = ensureReady(forInput: false) { throw error }
        let start = Date()
        let effectiveTimeout = min(max(timeoutSeconds, 1), 120)
        let deadline = start.addingTimeInterval(effectiveTimeout)
        let thresholdValue = threshold > 0 ? threshold : 0.02
        var reference = try await captureCurrentWindow().image

        switch mode {
        case "changed":
            while true {
                try await Task.sleep(nanoseconds: 400_000_000)
                let current = try await captureCurrentWindow().image
                if ImageUtil.meanAbsDifference(reference, current) >= thresholdValue {
                    return Date().timeIntervalSince(start)
                }
                if Date() >= deadline {
                    throw MirrorError("The screen did not change within \(Int(effectiveTimeout))s (difference threshold \(thresholdValue)).")
                }
            }
        case "stable":
            var stableRuns = 0
            while true {
                try await Task.sleep(nanoseconds: 400_000_000)
                let current = try await captureCurrentWindow().image
                if ImageUtil.meanAbsDifference(reference, current) < thresholdValue {
                    stableRuns += 1
                    if stableRuns >= 2 { return Date().timeIntervalSince(start) }
                } else {
                    stableRuns = 0
                }
                reference = current
                if Date() >= deadline {
                    throw MirrorError("The screen kept changing for \(Int(effectiveTimeout))s — it never went stable (threshold \(thresholdValue)).")
                }
            }
        default:
            throw MirrorError("Unknown mode \"\(mode)\". Use \"changed\" or \"stable\".")
        }
    }

    /// Screenshot with every OCR element boxed and numbered — coordinate
    /// debugging in one call. Returns the annotated image plus the elements
    /// (index order matches the drawn labels).
    public func annotatedScreenshot(maxWidth: Int?) async throws -> (shot: Screenshot, elements: [OCRElement]) {
        if let error = ensureReady(forInput: false) { throw error }
        let capture = try await captureCurrentWindow()
        lastImageSize = capture.geometry.imagePixelSize
        let elements = try MirrorOCR.recognizeText(in: capture.image, fast: false)
        let annotated = try ImageUtil.annotate(
            capture.image,
            boxes: elements.enumerated().map { (index, element) in (element.box, String(index)) })

        var image = annotated
        var scale = 1.0
        if let maxWidth, maxWidth > 0, image.width > maxWidth {
            let widthScale = Double(maxWidth) / Double(image.width)
            let longestSideCap = Int((Double(max(image.width, image.height)) * widthScale).rounded())
            let scaled = ImageUtil.downscaled(image, maxDimension: longestSideCap)
            scale = Double(image.width) / Double(scaled.width)
            image = scaled
        }
        let shot = Screenshot(
            pngData: try ImageUtil.pngData(from: image),
            pixelWidth: annotated.width,
            pixelHeight: annotated.height,
            coordinateScale: scale)
        return (shot, elements)
    }

    // MARK: - Pointing (pixel coordinates)

    /// Re-asserts frontmost IMMEDIATELY before posting input. ensureReady
    /// activated the window, but steps in between (geometry capture) take
    /// long enough for the user to refocus another app with a single
    /// keystroke in their terminal — and iPhone Mirroring silently drops
    /// input delivered while unfocused. activate() costs one window-server
    /// query when focus is already correct.
    private func assertFrontmostForInput() throws {
        guard bridge.activate() else {
            throw MirrorError(
                "Could not bring the iPhone Mirroring window to the front; input would be silently dropped.",
                remediation: "Click the iPhone Mirroring window once to focus it. If macOS prompted for the Automation (System Events) permission, grant it to the app hosting this server, then retry.")
        }
    }

    /// The pointer-engagement waypoint: the window center. Pointer gestures
    /// approach their target through it so the app's engagement transition
    /// (which discards deltas) is absorbed before the target-bound march.
    private static func engagementWaypoint(of geometry: WindowGeometry) -> CGPoint {
        CGPoint(x: geometry.boundsPoints.midX, y: geometry.boundsPoints.midY)
    }

    public func tap(x: Double, y: Double, expect: String? = nil, expectTimeout: Double = 10) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try assertFrontmostForInput()
        try MirrorInput.tap(at: geometry.screenPoint(fromPixelX: x, pixelY: y),
                            through: Self.engagementWaypoint(of: geometry))
        try await verifyExpectation(expect, timeout: expectTimeout, after: "tap")
    }

    /// Post-condition check for verified input: waits for `expect` to appear
    /// and converts a timeout into an input-shaped error — a tap that
    /// "succeeded" without its expected effect is this server's most
    /// dangerous failure mode.
    private func verifyExpectation(_ expect: String?, timeout: Double, after action: String) async throws {
        guard let expect else { return }
        do {
            _ = try await waitForText(expect, timeoutSeconds: timeout, exact: false)
        } catch {
            throw MirrorError(
                "The \(action) was posted, but \"\(expect)\" did not appear within \(Int(max(timeout, 1)))s.",
                remediation: "Take a screenshot: the \(action) may have missed its target, landed on a different element, or the screen changed differently than expected.")
        }
    }

    public func doubleTap(x: Double, y: Double) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try assertFrontmostForInput()
        try MirrorInput.doubleTap(at: geometry.screenPoint(fromPixelX: x, pixelY: y),
                                  through: Self.engagementWaypoint(of: geometry))
    }

    public func longPress(x: Double, y: Double, durationMs: Int) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try assertFrontmostForInput()
        try MirrorInput.longPress(at: geometry.screenPoint(fromPixelX: x, pixelY: y),
                                  durationMs: durationMs,
                                  through: Self.engagementWaypoint(of: geometry))
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try assertFrontmostForInput()
        try MirrorInput.swipe(
            from: geometry.screenPoint(fromPixelX: fromX, pixelY: fromY),
            to: geometry.screenPoint(fromPixelX: toX, pixelY: toY),
            durationMs: durationMs,
            through: Self.engagementWaypoint(of: geometry)
        )
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try assertFrontmostForInput()
        try MirrorInput.drag(
            from: geometry.screenPoint(fromPixelX: fromX, pixelY: fromY),
            to: geometry.screenPoint(fromPixelX: toX, pixelY: toY),
            durationMs: durationMs,
            through: Self.engagementWaypoint(of: geometry)
        )
    }

    // MARK: - Keyboard

    /// Returns skipped (untypeable) characters, empty when everything typed.
    public func typeText(_ text: String, submit: Bool) async throws -> String {
        if let error = ensureReady(forInput: true) { throw error }
        try assertFrontmostForInput()
        let skipped = try MirrorInput.typeText(text)
        if submit {
            usleep(Self.preReturnUs)
            try MirrorInput.pressKey(keyCode: 36)
        }
        return skipped
    }

    /// Paste render time before the user's clipboard is restored.
    static let pasteSettleUs: UInt32 = 700_000

    /// Pastes text into the focused phone field via the bridged pasteboard
    /// (⌘V) — the only full-fidelity path: emoji/CJK/accents survive, and
    /// long strings land instantly instead of keystroke-by-keystroke. The
    /// user's Mac clipboard is snapshotted and restored afterwards.
    public func pasteText(_ text: String, submit: Bool) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        try assertFrontmostForInput()
        let saved = MacPasteboard.snapshot()
        MacPasteboard.setString(text)
        defer { MacPasteboard.restore(saved) }
        try MirrorInput.pressKey(keyCode: 0x09, flags: .maskCommand)  // ⌘V
        usleep(Self.pasteSettleUs)
        if submit {
            try MirrorInput.pressKey(keyCode: 36)
        }
    }

    /// Presses ⌘C on the phone (copying any selection) and returns what the
    /// bridged pasteboard then holds. Also usable without the copy to just
    /// read the current clipboard.
    public func copyAndReadClipboard(pressCopy: Bool) async throws -> String? {
        if pressCopy {
            if let error = ensureReady(forInput: true) { throw error }
            try assertFrontmostForInput()
            try MirrorInput.pressKey(keyCode: 0x08, flags: .maskCommand)  // ⌘C
            usleep(Self.pasteSettleUs)
        }
        return MacPasteboard.string()
    }

    /// Full mirroring-app restart: the only cure for the ZOMBIE state (video
    /// streams but every input is silently dropped — a wedged gesture stream
    /// can cause it). Quit, wait for exit, relaunch, resume.
    public func restartMirroring() async throws -> Status {
        if let app = bridge.findProcess() {
            app.terminate()
            for _ in 0..<10 where bridge.findProcess() != nil {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if bridge.findProcess() != nil {
                app.forceTerminate()
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        try await bridge.launchApp()
        _ = ensureReady(forInput: false)  // auto-resume if it comes up paused
        return status()
    }

    // MARK: - Doctor

    public struct DoctorReport: Sendable {
        public var accessibility = false
        public var screenRecording = false
        public var postEventAccess = false
        public var automation: Bool?
        public var sessionState = ""
        public var windowLine = "no window"
        public var frontmostLine = ""
        public var captureLine = ""
        public var inputDeliveryLine = ""

        public func describe() -> String {
            func mark(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }
            var lines = ["== iphone-mirror doctor =="]
            lines.append("[\(mark(accessibility))] Accessibility permission")
            lines.append("[\(mark(screenRecording))] Screen Recording permission")
            lines.append("[\(mark(postEventAccess))] Post-event access (synthetic input accepted by macOS)")
            switch automation {
            case true?: lines.append("[PASS] Automation permission (System Events)")
            case false?: lines.append("[FAIL] Automation permission (System Events) — resume clicks and the activation fallback need it; grant in System Settings → Privacy & Security → Automation")
            default: lines.append("[????] Automation permission (System Events) — undetermined; it will be requested on first use")
            }
            lines.append("Session: \(sessionState)")
            lines.append("Window: \(windowLine)")
            if !frontmostLine.isEmpty { lines.append(frontmostLine) }
            if !captureLine.isEmpty { lines.append(captureLine) }
            if !inputDeliveryLine.isEmpty { lines.append(inputDeliveryLine) }
            return lines.joined(separator: "\n")
        }
    }

    /// Non-destructive end-to-end self-test: all four permissions, session
    /// and window state, a capture round-trip, and the input-delivery probe
    /// (march the cursor and verify events moved it — no clicks posted).
    public func doctor() async -> DoctorReport {
        var report = DoctorReport()
        let permissions = PermissionStatus.current()
        report.accessibility = permissions.accessibility
        report.screenRecording = permissions.screenRecording
        report.postEventAccess = PermissionStatus.postEventAccess()
        report.automation = PermissionStatus.automationForSystemEvents()
        report.sessionState = bridge.state().rawValue

        if let info = bridge.windowInfo() {
            let b = info.bounds
            report.windowLine = "id=\(info.windowID) origin=(\(Int(b.origin.x)), \(Int(b.origin.y))) size=\(Int(b.width))x\(Int(b.height)) points"
            + (info.windowID == 0 ? " (AX fallback — no window ID; capture may degrade)" : "")

            if let front = bridge.frontmostPID() {
                report.frontmostLine = front == info.pid
                    ? "[PASS] iPhone Mirroring is frontmost"
                    : "[info] Frontmost app pid=\(front) (mirroring is pid \(info.pid)); input tools will activate it"
            } else {
                report.frontmostLine = "[FAIL] Frontmost query returned nothing — CGWindowList unavailable?"
            }

            if report.screenRecording {
                let start = Date()
                do {
                    let capture = try await MirrorCapture.capture(windowInfo: info)
                    report.captureLine = "[PASS] Capture: \(capture.image.width)x\(capture.image.height) px in \(String(format: "%.2f", Date().timeIntervalSince(start)))s"
                } catch {
                    report.captureLine = "[FAIL] Capture: \(error)"
                }
            }

            if report.accessibility, bridge.state() == .connected {
                let center = CGPoint(x: b.midX, y: b.midY)
                bridge.activate()
                do {
                    try MirrorInput.placeCursor(at: center)
                    report.inputDeliveryLine = "[PASS] Input delivery: cursor march verified (no clicks posted)"
                } catch {
                    report.inputDeliveryLine = "[FAIL] Input delivery: \(error)"
                }
            }
        }
        return report
    }

    public func pressKey(spec: String) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let chord = try KeyMap.chord(from: spec)
        try assertFrontmostForInput()
        try MirrorInput.pressKey(keyCode: chord.keyCode, flags: MirrorInput.eventFlags(for: chord.modifiers))
    }

    public func shake() async throws {
        if let error = ensureReady(forInput: true) { throw error }
        try assertFrontmostForInput()
        try MirrorInput.pressKey(keyCode: 0x06, flags: [.maskControl, .maskCommand])  // ⌃⌘Z
    }

    // MARK: - System navigation

    public func systemAction(_ item: String) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        switch bridge.triggerViewMenuAction(item: item) {
        case .performed:
            break
        case .useShortcut(let keycode):
            try assertFrontmostForInput()
            try MirrorInput.pressKey(keyCode: keycode, flags: .maskCommand)
        case .unsupported:
            throw MirrorError("Unsupported system action \"\(item)\".")
        }
    }

    public func home() async throws { try await systemAction("Home Screen") }
    public func appSwitcher() async throws { try await systemAction("App Switcher") }
    public func spotlight() async throws { try await systemAction("Spotlight") }

    /// Launches an iPhone app via Spotlight: open, type name, Return.
    public func launchApp(named name: String) async throws {
        try await spotlight()
        usleep(Self.spotlightAppearanceUs)
        let skipped = try MirrorInput.typeText(name)
        guard skipped.isEmpty else {
            throw MirrorError(
                "App name contains characters that cannot be typed via the mirrored keyboard: \(skipped)",
                remediation: "Use the app's ASCII name, or navigate to it manually via screenshots and taps.")
        }
        usleep(Self.searchResultsUs)
        try MirrorInput.pressKey(keyCode: 36)  // Return launches top hit
    }

    /// Opens a URL: launch Safari, focus the address bar (⌘L works through
    /// mirroring), type, Return.
    public func openURL(_ url: String) async throws {
        try await launchApp(named: "Safari")
        usleep(Self.safariLoadUs)
        try MirrorInput.pressKey(keyCode: 0x25, flags: .maskCommand)  // ⌘L
        usleep(Self.addressBarUs)
        let skipped = try MirrorInput.typeText(url)
        guard skipped.isEmpty else {
            throw MirrorError("URL contains untypeable characters: \(skipped)")
        }
        usleep(Self.preReturnUs)
        try MirrorInput.pressKey(keyCode: 36)
    }

    // MARK: - OCR helpers

    /// OCR of the current screen; boxes are in full-resolution pixel space.
    public func readScreen(fast: Bool = false) async throws -> [OCRElement] {
        if let error = ensureReady(forInput: false) { throw error }
        let capture = try await captureCurrentWindow()
        lastImageSize = capture.geometry.imagePixelSize
        return try MirrorOCR.recognizeText(in: capture.image, fast: fast)
    }

    public func findText(_ query: String, exact: Bool) async throws -> [OCRElement] {
        TextMatch.find(query, in: try await readScreen(), exact: exact)
    }

    /// OCR-locate `query` and tap the center of the `index`-th match.
    public func tapText(
        _ query: String, index: Int, exact: Bool,
        expect: String? = nil, expectTimeout: Double = 10
    ) async throws -> OCRElement {
        let matches = try await findText(query, exact: exact)
        guard !matches.isEmpty else {
            throw MirrorError(
                "No on-screen text matched \"\(query)\".",
                remediation: "Take a screenshot to see the current screen; the text may be off-screen (try scroll_to) or rendered as an icon.")
        }
        guard index >= 0, index < matches.count else {
            throw MirrorError("Match index \(index) out of range: only \(matches.count) match(es) for \"\(query)\".")
        }
        let element = matches[index]
        try await tap(x: element.center.x, y: element.center.y, expect: expect, expectTimeout: expectTimeout)
        return element
    }

    /// Finds a template image (a crop from a previous screenshot) on the
    /// current screen via normalized cross-correlation. Returns matches in
    /// full-resolution pixel coordinates, best first.
    public func findImage(
        templateData: Data, minScore: Double, multiScale: Bool
    ) async throws -> [TemplateMatch.Match] {
        if let error = ensureReady(forInput: false) { throw error }
        guard let source = CGImageSourceCreateWithData(templateData as CFData, nil),
              let template = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MirrorError("The template is not a decodable image (PNG/JPEG).")
        }
        let capture = try await captureCurrentWindow()
        lastImageSize = capture.geometry.imagePixelSize
        let scales = multiScale ? [1.0, 0.75, 0.9, 1.15, 1.35] : [1.0]
        return TemplateMatch.find(
            template: template, in: capture.image,
            minScore: min(max(minScore, 0.3), 0.999), scales: scales)
    }

    /// Locates the template and taps the best match's center.
    public func tapImage(
        templateData: Data, minScore: Double, multiScale: Bool,
        expect: String?, expectTimeout: Double
    ) async throws -> TemplateMatch.Match {
        let matches = try await findImage(
            templateData: templateData, minScore: minScore, multiScale: multiScale)
        guard let best = matches.first else {
            throw MirrorError(
                "No on-screen region matched the template (min score \(minScore)).",
                remediation: "Crop the template from a CURRENT full-resolution screenshot (same scale), or lower min_score / set multi_scale=true.")
        }
        try await tap(x: best.center.x, y: best.center.y, expect: expect, expectTimeout: expectTimeout)
        return best
    }

    /// Polls the screen until `query` appears or the timeout elapses.
    /// Returns the elapsed seconds on success.
    public func waitForText(_ query: String, timeoutSeconds: Double, exact: Bool) async throws -> Double {
        let start = Date()
        let effectiveTimeout = min(max(timeoutSeconds, 1), 120)
        let deadline = start.addingTimeInterval(effectiveTimeout)
        while true {
            let matches = TextMatch.find(query, in: try await readScreen(fast: true), exact: exact)
            if !matches.isEmpty { return Date().timeIntervalSince(start) }
            if Date() >= deadline {
                throw MirrorError("Text \"\(query)\" did not appear within \(Int(effectiveTimeout))s.")
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    /// Swipes repeatedly until `query` becomes visible. Direction is the
    /// finger direction: "up" swipes content upward (scrolls down the page).
    public func scrollTo(_ query: String, direction: String, maxSwipes: Int) async throws -> OCRElement {
        let geometry = try await currentGeometry()
        let width = geometry.imagePixelSize.width
        let height = geometry.imagePixelSize.height
        let centerX = width / 2
        let centerY = height / 2
        let travel = height * 0.3

        let (from, to): (CGPoint, CGPoint)
        switch direction.lowercased() {
        case "up":
            (from, to) = (CGPoint(x: centerX, y: centerY + travel / 2), CGPoint(x: centerX, y: centerY - travel / 2))
        case "down":
            (from, to) = (CGPoint(x: centerX, y: centerY - travel / 2), CGPoint(x: centerX, y: centerY + travel / 2))
        case "left":
            (from, to) = (CGPoint(x: centerX + width * 0.3, y: centerY), CGPoint(x: centerX - width * 0.3, y: centerY))
        case "right":
            (from, to) = (CGPoint(x: centerX - width * 0.3, y: centerY), CGPoint(x: centerX + width * 0.3, y: centerY))
        default:
            throw MirrorError("Unknown scroll direction \"\(direction)\". Use up, down, left, or right.")
        }

        let swipeBudget = max(1, min(maxSwipes, 20))
        // Check → swipe → … → check: the screen is re-read AFTER the final
        // swipe too, so text revealed by the last swipe is still found.
        for _ in 0..<swipeBudget {
            let matches = TextMatch.find(query, in: try await readScreen(fast: true), exact: false)
            if let first = matches.first { return first }
            try await swipe(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y, durationMs: 400)
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        if let found = TextMatch.find(query, in: try await readScreen(fast: true), exact: false).first {
            return found
        }
        throw MirrorError("Text \"\(query)\" not found after \(swipeBudget) \(direction) swipes.")
    }
}
