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
    static let resumeSettleUs: UInt32 = 2_000_000

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
            bridge.activate()
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
        // AX press missing or not honored: real HID click at the button.
        if let center = bridge.resumeButtonCenter() {
            bridge.activate()
            try? MirrorInput.tap(at: center)
            usleep(Self.resumeSettleUs)
        }
    }

    // MARK: - Coordinate mapping

    /// Current geometry: fresh window bounds + last screenshot pixel size.
    /// Captures a screenshot first when none exists yet (the pixel contract
    /// needs an image size).
    func currentGeometry() async throws -> WindowGeometry {
        guard let info = bridge.windowInfo() else { throw MirrorError.windowNotFound() }
        if lastImageSize == nil {
            let capture = try await MirrorCapture.capture(windowInfo: info)
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
        guard let info = bridge.windowInfo() else { throw MirrorError.windowNotFound() }
        let capture = try await MirrorCapture.capture(windowInfo: info)
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

    // MARK: - Pointing (pixel coordinates)

    public func tap(x: Double, y: Double) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try MirrorInput.tap(at: geometry.screenPoint(fromPixelX: x, pixelY: y))
    }

    public func doubleTap(x: Double, y: Double) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try MirrorInput.doubleTap(at: geometry.screenPoint(fromPixelX: x, pixelY: y))
    }

    public func longPress(x: Double, y: Double, durationMs: Int) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try MirrorInput.longPress(at: geometry.screenPoint(fromPixelX: x, pixelY: y), durationMs: durationMs)
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try MirrorInput.swipe(
            from: geometry.screenPoint(fromPixelX: fromX, pixelY: fromY),
            to: geometry.screenPoint(fromPixelX: toX, pixelY: toY),
            durationMs: durationMs
        )
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let geometry = try await currentGeometry()
        try MirrorInput.drag(
            from: geometry.screenPoint(fromPixelX: fromX, pixelY: fromY),
            to: geometry.screenPoint(fromPixelX: toX, pixelY: toY),
            durationMs: durationMs
        )
    }

    // MARK: - Keyboard

    /// Returns skipped (untypeable) characters, empty when everything typed.
    public func typeText(_ text: String, submit: Bool) async throws -> String {
        if let error = ensureReady(forInput: true) { throw error }
        let skipped = try MirrorInput.typeText(text)
        if submit {
            usleep(Self.preReturnUs)
            try MirrorInput.pressKey(keyCode: 36)
        }
        return skipped
    }

    public func pressKey(spec: String) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        let chord = try KeyMap.chord(from: spec)
        try MirrorInput.pressKey(keyCode: chord.keyCode, flags: MirrorInput.eventFlags(for: chord.modifiers))
    }

    public func shake() async throws {
        if let error = ensureReady(forInput: true) { throw error }
        try MirrorInput.pressKey(keyCode: 0x06, flags: [.maskControl, .maskCommand])  // ⌃⌘Z
    }

    // MARK: - System navigation

    public func systemAction(_ item: String) async throws {
        if let error = ensureReady(forInput: true) { throw error }
        switch bridge.triggerViewMenuAction(item: item) {
        case .performed:
            break
        case .useShortcut(let keycode):
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
        guard let info = bridge.windowInfo() else { throw MirrorError.windowNotFound() }
        let capture = try await MirrorCapture.capture(windowInfo: info)
        lastImageSize = capture.geometry.imagePixelSize
        return try MirrorOCR.recognizeText(in: capture.image, fast: fast)
    }

    public func findText(_ query: String, exact: Bool) async throws -> [OCRElement] {
        TextMatch.find(query, in: try await readScreen(), exact: exact)
    }

    /// OCR-locate `query` and tap the center of the `index`-th match.
    public func tapText(_ query: String, index: Int, exact: Bool) async throws -> OCRElement {
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
        try await tap(x: element.center.x, y: element.center.y)
        return element
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
