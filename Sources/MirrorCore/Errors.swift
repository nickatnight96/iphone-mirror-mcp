import Foundation

/// Error type for every failure surfaced through an MCP tool result.
/// `remediation`, when present, tells the caller (usually an LLM driving the
/// tools) what a human needs to do to unblock — e.g. grant a TCC permission.
public struct MirrorError: Error, CustomStringConvertible, Sendable, Equatable {
    public let message: String
    public let remediation: String?

    public init(_ message: String, remediation: String? = nil) {
        self.message = message
        self.remediation = remediation
    }

    public var description: String {
        if let remediation { return "\(message)\nRemediation: \(remediation)" }
        return message
    }
}

extension MirrorError {
    public static func windowNotFound() -> MirrorError {
        MirrorError(
            "The iPhone Mirroring window was not found on screen.",
            remediation: "Open the iPhone Mirroring app (or call the mirror_launch tool), make sure the iPhone is paired, nearby, and locked, and that the mirroring session is connected. The window must not be minimized."
        )
    }

    public static func screenRecordingDenied() -> MirrorError {
        MirrorError(
            "Screen Recording permission has not been granted, so the iPhone Mirroring window cannot be captured.",
            remediation: "Open System Settings → Privacy & Security → Screen & System Audio Recording and enable the app that launched this MCP server (e.g. your terminal or Claude), then restart the server."
        )
    }

    public static func accessibilityDenied() -> MirrorError {
        MirrorError(
            "Accessibility permission has not been granted, so synthetic taps/keystrokes cannot be sent.",
            remediation: "Open System Settings → Privacy & Security → Accessibility and enable the app that launched this MCP server (e.g. your terminal or Claude), then restart the server."
        )
    }
}
