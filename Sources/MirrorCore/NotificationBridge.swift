import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads and clicks notification banners in macOS Notification Center.
///
/// While iPhone Mirroring is active, the phone's notifications are delivered
/// to the MAC's Notification Center — so this is how automated flows observe
/// "a push/message arrived" and open it (clicking a mirrored iPhone
/// notification opens the app in the mirroring window). Works for Mac-native
/// notifications too, which is what the live test posts.
public enum NotificationBridge {
    public static let bundleID = "com.apple.notificationcenterui"

    public struct Banner: Sendable, Equatable {
        /// Every text line found in the banner (app name, title, body …).
        public let lines: [String]
        /// Screen frame of the banner (CG top-left-origin coordinates).
        public let frame: CGRect
    }

    static func process() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }

    /// The banners currently on screen, top-to-bottom. Throws with the AX
    /// error code when the query itself fails — several AX behaviors differ
    /// between CLI processes and the running server, so failures must be
    /// visible, not an indistinguishable "no banners".
    public static func bannersDetailed() throws -> [Banner] {
        guard let app = process() else {
            throw MirrorError("The NotificationCenter process is not running.")
        }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard axError == .success else {
            throw MirrorError(
                "The AX window query to Notification Center failed (AXError \(axError.rawValue)).",
                remediation: "Check the Accessibility permission for the app hosting this server; AXError -25204 means the query cannot complete from this process context.")
        }
        guard let windows = windowsRef as? [AXUIElement] else { return [] }
        var results: [Banner] = []
        for window in windows {
            guard let frame = MirrorWindowBridge.axGeometry(of: window) else { continue }
            // Ignore zero-size bookkeeping windows.
            guard frame.width > 40, frame.height > 20 else { continue }
            var lines: [String] = []
            collectText(from: window, depth: 0, into: &lines)
            guard !lines.isEmpty else { continue }
            results.append(Banner(lines: lines, frame: frame))
        }
        return results.sorted { $0.frame.origin.y < $1.frame.origin.y }
    }

    /// Error-swallowing variant for callers that treat failures as "none".
    public static func banners() -> [Banner] {
        (try? bannersDetailed()) ?? []
    }

    private static let maxDepth = 10

    static func collectText(from element: AXUIElement, depth: Int, into lines: inout [String]) {
        if depth > maxDepth { return }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == kAXStaticTextRole as String {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let text = valueRef as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectText(from: child, depth: depth + 1, into: &lines)
        }
    }

    /// Formats banners for a tool result. Pure, unit-tested.
    public static func describe(_ banners: [Banner]) -> String {
        guard !banners.isEmpty else {
            return "No notification banners are currently on screen. (Banners disappear after a few seconds — poll right after triggering one, or check Notification Center manually.)"
        }
        return banners.enumerated().map { index, banner in
            "\(index): \(banner.lines.joined(separator: " — "))"
        }.joined(separator: "\n")
    }

    /// Clicks the banner at `index` (as listed by `banners()`), which opens
    /// the notification — for mirrored iPhone notifications, in the
    /// mirroring window. Mac-native UI, so a System Events click is
    /// position-authoritative here.
    public static func click(index: Int) throws -> Banner {
        let current = banners()
        guard !current.isEmpty else {
            throw MirrorError("No notification banners are on screen to click.")
        }
        guard index >= 0, index < current.count else {
            throw MirrorError("Banner index \(index) out of range: \(current.count) banner(s) on screen.")
        }
        let banner = current[index]
        let center = CGPoint(x: banner.frame.midX, y: banner.frame.midY)
        guard MirrorWindowBridge.systemEventsClick(at: center) else {
            throw MirrorError(
                "Could not click the banner (System Events click failed).",
                remediation: "Grant the Automation (System Events) permission to the app hosting this server.")
        }
        return banner
    }
}
