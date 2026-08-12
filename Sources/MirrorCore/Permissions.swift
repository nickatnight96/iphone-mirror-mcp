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
