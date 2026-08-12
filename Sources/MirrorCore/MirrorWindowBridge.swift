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
/// Two hard-won facts shape this type (both observed by the mirroir-mcp
/// project and verified against its sources):
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

    /// Window bounds from CGWindowList — the compositor's authoritative
    /// position (AX can lag after focus/Space switches).
    public func windowInfo() -> MirrorWindowInfo? {
        guard let app = findProcess() else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
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
            // Ignore tiny windows (tooltips, the "connecting" toast).
            if bounds.width < 100 || bounds.height < 100 { continue }
            return MirrorWindowInfo(windowID: windowNumber, bounds: bounds, pid: pid)
        }
        // Fall back to AX geometry when CGWindowList has no match (e.g. the
        // window sits on another Space, which optionOnScreenOnly excludes).
        guard let (element, axPid) = mainWindowElement(),
              let geometry = Self.axGeometry(of: element) else { return nil }
        return MirrorWindowInfo(windowID: 0, bounds: geometry, pid: axPid)
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

    /// Brings iPhone Mirroring to the front. No-op when already active —
    /// re-activating an active app disturbs event routing and drops the next
    /// click. `NSRunningApplication.activate()` cannot switch macOS Spaces,
    /// so when it fails to take effect we fall back to AppleScript System
    /// Events (which needs the Automation permission).
    ///
    /// Returns true when focus changed (caller should re-query window bounds
    /// and wait `activationSettleUs`).
    @discardableResult
    public func activate() -> Bool {
        guard let app = findProcess() else { return false }
        if app.isActive { return false }
        app.activate()
        usleep(Self.activationSettleUs)
        if findProcess()?.isActive == true { return true }
        Self.runAppleScriptOnMainThread("""
            tell application "System Events"
                tell process "\(Self.processName)"
                    set frontmost to true
                end tell
            end tell
            """)
        usleep(Self.activationSettleUs)
        return true
    }

    /// NSAppleScript is documented main-thread-only; the caller usually runs
    /// on an actor's cooperative thread, so hop to the main queue for the
    /// execution itself (the surrounding sleeps stay off the main thread).
    static func runAppleScriptOnMainThread(_ source: String) {
        let work = {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
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
