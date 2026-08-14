import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Connection state of the iPhone Mirroring session.
public enum MirroringState: String, Sendable {
    case connected      // live video stream, accepting input
    case paused         // showing a resume/interruption overlay
    case notRunning     // the app is not running
    case noWindow       // app running but no usable window yet
}

/// Live window info for the mirroring window.
public struct MirrorWindowInfo: Sendable {
    public let windowID: UInt32
    /// Bounds in CG global coordinates (origin top-left of main display, y down).
    public let bounds: CGRect
    public let pid: pid_t
}

/// Bridge to the macOS iPhone Mirroring app (`com.apple.ScreenContinuity`).
///
/// Two hard-won facts about the host platform shape this type, both verified
/// against the live app:
/// - The mirroring window does not appear in `AXWindows`; it is only
///   reachable via `AXMainWindow`.
/// - `NSWorkspace`'s runningApplications snapshot freezes in a stdio server
///   that never pumps its run loop, so every process lookup must query
///   Launch Services fresh (`NSRunningApplication.runningApplications(withBundleIdentifier:)`).
public final class MirrorWindowBridge: @unchecked Sendable {
    public static let bundleID = "com.apple.ScreenContinuity"
    public static let processName = "iPhone Mirroring"
    public static let appPath = "/System/Applications/iPhone Mirroring.app"

    /// Post-activation settle: input posted before the focus transition
    /// finishes is silently dropped.
    public static let activationSettleUs: UInt32 = 300_000

    /// Extra settle after an activation that actually CHANGED focus: the
    /// window (hide-on-blur) plays an unhide animation during which the
    /// pointer-integration machinery discards ALL input — moves, deltas,
    /// clicks (observed live 2026-08-13: identical click sequences failed
    /// at 300ms after unhide and landed after a 1.5s wait). Skipped
    /// entirely when the app was already frontmost.
    public static let unhideSettleUs: UInt32 = 1_500_000

    public init() {}

    /// Live lookup of the iPhone Mirroring process.
    public func findProcess() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .first { !$0.isTerminated }
    }

    /// The AX element for the mirroring window (AXMainWindow only).
    func mainWindowElement() -> (element: AXUIElement, pid: pid_t)? {
        guard let app = findProcess() else { return nil }
        let pid = app.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (unsafeDowncast(window, to: AXUIElement.self), pid)
    }

    /// The mirroring app owns several menu-bar-sized phantom windows
    /// (observed live: four at 1512×33 plus a 64×64) — every window lookup
    /// must size-filter with BOTH dimensions or capture grabs a blank strip.
    static func isUsableWindowSize(width: CGFloat, height: CGFloat) -> Bool {
        width >= 100 && height >= 100
    }

    /// Window bounds from CGWindowList — the compositor's authoritative
    /// position (AX can lag after focus/Space switches).
    public func windowInfo() -> MirrorWindowInfo? {
        guard let app = findProcess() else { return nil }
        let pid = app.processIdentifier
        if let info = Self.windowMatch(pid: pid, options: .optionOnScreenOnly) { return info }
        // The window may be hidden or on another Space. optionAll still
        // lists it WITH its real window ID — which downstream capture
        // needs: with windowID 0, SCK's bundle-based guess can land on one
        // of the app's phantom windows and return a blank strip.
        if let info = Self.windowMatch(pid: pid, options: .optionAll) { return info }
        // Last resort: AX geometry (no window ID).
        guard let (element, axPid) = mainWindowElement(),
              let geometry = Self.axGeometry(of: element) else { return nil }
        return MirrorWindowInfo(windowID: 0, bounds: geometry, pid: axPid)
    }

    private static func windowMatch(pid: pid_t, options: CGWindowListOption) -> MirrorWindowInfo? {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = entry[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            guard isUsableWindowSize(width: bounds.width, height: bounds.height) else { continue }
            return MirrorWindowInfo(windowID: windowNumber, bounds: bounds, pid: pid)
        }
        return nil
    }

    static func axGeometry(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Detect the session state. When connected, the mirroring surface is an
    /// opaque video with NO AX children; a paused/interrupted session shows
    /// overlay UI, which appears as children of the window's hosting view.
    public func state() -> MirroringState {
        guard findProcess() != nil else { return .notRunning }
        guard let (window, _) = mainWindowElement() else { return .noWindow }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement], let hostingView = children.first else {
            return .noWindow
        }
        var hostChildrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(hostingView, kAXChildrenAttribute as CFString, &hostChildrenRef)
        if let hostChildren = hostChildrenRef as? [AXUIElement], !hostChildren.isEmpty {
            return .paused
        }
        return .connected
    }

    /// Titles of overlay buttons that free a paused/interrupted session,
    /// matched case-insensitively (includes common localized variants).
    static let dismissButtonTitles: Set<String> = [
        "ok", "resume", "reprendre", "continuer", "réessayer", "reessayer", "retry",
        "connect", "connecter", "se connecter",  // "iPhone in Use" overlay (observed live 2026-08-13)
    ]

    /// Finds the paused-overlay dismiss button (e.g. "Resume"/"OK") and
    /// presses it via AX. Returns true when a button was pressed.
    public func pressResumeButton() -> Bool {
        guard let (window, _) = mainWindowElement() else { return false }
        guard let button = Self.dismissButton(under: window, depth: 0) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Screen-center of the dismiss button, for a real HID click when the AX
    /// press is not honored.
    public func resumeButtonCenter() -> CGPoint? {
        guard let (window, _) = mainWindowElement(),
              let button = Self.dismissButton(under: window, depth: 0),
              let geometry = Self.axGeometry(of: button) else { return nil }
        return CGPoint(x: geometry.midX, y: geometry.midY)
    }

    private static let maxOverlaySearchDepth = 8

    static func dismissButton(under element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > maxOverlaySearchDepth { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == kAXButtonRole as String,
           let label = buttonLabel(element), dismissButtonTitles.contains(label) {
            return element
        }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = dismissButton(under: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func buttonLabel(_ element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Outcome of a View-menu trigger attempt.
    public enum MenuActionOutcome: Equatable, Sendable {
        /// The AX menu press succeeded.
        case performed
        /// AX lookup missed (localized menu titles); caller should post the
        /// locale-invariant ⌘-digit shortcut with this keycode.
        case useShortcut(keycode: UInt16)
        case unsupported
    }

    /// Triggers a View-menu action by AX menu title, falling back to the
    /// locale-invariant ⌘-digit shortcut (⌘1 Home Screen, ⌘2 App Switcher,
    /// ⌘3 Spotlight) when localized menu titles defeat the AX lookup.
    public func triggerViewMenuAction(item itemName: String) -> MenuActionOutcome {
        if axTriggerMenuAction(menu: "View", item: itemName) { return .performed }
        switch itemName.lowercased() {
        case "home screen": return .useShortcut(keycode: 0x12)   // kVK_ANSI_1
        case "app switcher": return .useShortcut(keycode: 0x13)  // kVK_ANSI_2
        case "spotlight": return .useShortcut(keycode: 0x14)     // kVK_ANSI_3
        default: return .unsupported
        }
    }

    func axTriggerMenuAction(menu menuName: String, item itemName: String) -> Bool {
        guard let app = findProcess() else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarValue = menuBarRef, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return false
        }
        let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
        var menusRef: CFTypeRef?
        AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &menusRef)
        guard let menus = menusRef as? [AXUIElement] else { return false }
        for menuItem in menus {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(menuItem, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, title == menuName else { continue }
            var submenuRef: CFTypeRef?
            AXUIElementCopyAttributeValue(menuItem, kAXChildrenAttribute as CFString, &submenuRef)
            guard let submenus = submenuRef as? [AXUIElement], let submenu = submenus.first else { continue }
            var itemsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(submenu, kAXChildrenAttribute as CFString, &itemsRef)
            guard let items = itemsRef as? [AXUIElement] else { continue }
            for item in items {
                var itemTitleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitleRef)
                if let itemTitle = itemTitleRef as? String, itemTitle == itemName {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// PID of the application that currently has focus, queried live from
    /// the window server: CGWindowList returns windows front-to-back, and
    /// the owner of the frontmost normal-layer window is the active app.
    ///
    /// Two tempting alternatives are BROKEN in a stdio MCP server:
    /// - `NSRunningApplication.isActive` is refreshed by the main run loop,
    ///   which this process never pumps — it reports stale values forever
    ///   (same failure class as the NSWorkspace snapshot freeze above).
    /// - The system-wide AX focused-application query returns
    ///   kAXErrorCannotComplete (-25204) from a run-loop-less agent process
    ///   — while working fine in test runners, which DO pump a run loop, so
    ///   only a live check in the real server context catches it.
    public func frontmostPID() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return pid
        }
        return nil
    }

    /// Brings iPhone Mirroring to the front and confirms it actually took
    /// focus. No-op when the live focus check says it is already frontmost —
    /// re-activating an active app disturbs event routing and drops the next
    /// click. `NSRunningApplication.activate()` is subject to cooperative
    /// activation and cannot switch macOS Spaces, so when it does not take
    /// effect we fall back to AppleScript System Events (which needs the
    /// Automation permission).
    ///
    /// Returns true when the app is frontmost afterwards (or focus cannot be
    /// queried); false means every activation path failed — input posted in
    /// that state is silently dropped, so callers must surface an error
    /// rather than proceed.
    @discardableResult
    /// Polls for the app becoming frontmost instead of sleeping a fixed
    /// settle: activation usually lands within a few frames, and the fixed
    /// 300ms wait charged the full amount to every stage of the fallback
    /// chain (measured on the 2026-08-13 live probe: an activation-from-
    /// background tap cost 5.8s, much of it these fixed waits).
    private func becameFrontmost(_ pid: pid_t, withinUs timeout: UInt32) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000_000)
        while Date() < deadline {
            if frontmostPID() == pid { return true }
            usleep(25_000)
        }
        return frontmostPID() == pid
    }

    public func activate() -> Bool {
        guard let app = findProcess() else { return false }
        let pid = app.processIdentifier
        if frontmostPID() == pid { return true }
        app.activate()
        if becameFrontmost(pid, withinUs: Self.activationSettleUs) {
            usleep(Self.unhideSettleUs)
            return true
        }
        // Cooperative activation routinely DENIES a background process's
        // NSRunningApplication.activate(). Routing the request through
        // Launch Services — the same path mirror_launch uses — is honored
        // from this server's context.
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: Self.appPath), configuration: configuration
        ) { _, _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 3)
        if becameFrontmost(pid, withinUs: Self.activationSettleUs) {
            usleep(Self.unhideSettleUs)
            return true
        }
        Self.runAppleScriptOnMainThread("""
            tell application "System Events"
                tell process "\(Self.processName)"
                    set frontmost to true
                end tell
            end tell
            """)
        _ = becameFrontmost(pid, withinUs: Self.activationSettleUs)
        guard let front = frontmostPID() else {
            // Focus query unavailable: assume the fallbacks worked rather
            // than fail input that may well deliver.
            return true
        }
        if front == pid {
            usleep(Self.unhideSettleUs)
            return true
        }
        return false
    }

    /// NSAppleScript is documented main-thread-only; the caller usually runs
    /// on an actor's cooperative thread, so hop to the main queue for the
    /// execution itself (the surrounding sleeps stay off the main thread).
    /// Returns false when the script errored (e.g. the Automation
    /// permission for System Events is missing).
    @discardableResult
    static func runAppleScriptOnMainThread(_ source: String) -> Bool {
        let work: () -> Bool = {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            return errorInfo == nil
        }
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    /// Clicks via System Events at a screen position. Unlike posted CGEvent
    /// clicks — which iPhone Mirroring resolves at its INTERNAL pointer
    /// position, stale until the pointer has fully re-engaged — System
    /// Events clicks are position-authoritative: every one observed live
    /// (2026-08-12/13) landed exactly where aimed, regardless of pointer
    /// engagement state. Requires the app to be frontmost (System Events
    /// clicks the frontmost process's UI at that point) and the Automation
    /// permission; returns false when the script fails so callers can fall
    /// back to a CGEvent click.
    public static func systemEventsClick(at point: CGPoint) -> Bool {
        runAppleScriptOnMainThread(systemEventsClickSource(at: point))
    }

    static func systemEventsClickSource(at point: CGPoint) -> String {
        "tell application \"System Events\" to click at {\(Int(point.x.rounded())), \(Int(point.y.rounded()))}"
    }

    /// Launches the iPhone Mirroring app if needed and waits for a window.
    public func launchApp(timeout: TimeInterval = 15) async throws {
        if findProcess() == nil {
            let url = URL(fileURLWithPath: Self.appPath)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            activate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if windowInfo() != nil { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw MirrorError(
            "iPhone Mirroring launched but no window appeared within \(Int(timeout))s.",
            remediation: "Open the iPhone Mirroring app manually and complete pairing (iPhone nearby, locked, Bluetooth/Wi-Fi on), then retry."
        )
    }
}
