import ApplicationServices
import CoreGraphics
import Foundation

/// TCC permission status for the process hosting this MCP server.
/// Both permissions attach to the *responsible* app — usually the terminal or
/// Claude app that launched the server binary.
public struct PermissionStatus: Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool

    public static func current() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    /// Whether posted CGEvents are accepted (separate TCC gate from the
    /// Accessibility trust check, usually granted together).
    public static func postEventAccess() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Whether this process may automate System Events (the Automation
    /// permission) — needed by the resume-overlay clicks and the AppleScript
    /// activation fallback. nil = undetermined (macOS has not asked yet, or
    /// System Events is not running).
    public static func automationForSystemEvents() -> Bool? {
        var address = AEAddressDesc()
        let bundleID = "com.apple.systemevents"
        let status = bundleID.utf8CString.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count - 1, &address)
        }
        guard status == noErr else { return nil }
        defer { AEDisposeDesc(&address) }
        switch AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, false) {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return nil  // would-require-consent, target not running, …
        }
    }

    public var description: String {
        var lines: [String] = []
        lines.append("Accessibility (synthetic input): \(accessibility ? "granted" : "MISSING")")
        lines.append("Screen Recording (window capture): \(screenRecording ? "granted" : "MISSING")")
        if !accessibility {
            lines.append("→ Grant in System Settings → Privacy & Security → Accessibility for the app that runs this server (terminal/Claude), then restart the server.")
        }
        if !screenRecording {
            lines.append("→ Grant in System Settings → Privacy & Security → Screen & System Audio Recording for the app that runs this server, then restart the server.")
        }
        return lines.joined(separator: "\n")
    }
}
