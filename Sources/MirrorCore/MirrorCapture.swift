import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A captured frame of the mirroring window plus the geometry needed to map
/// screenshot pixels back to screen points.
public struct CaptureResult: Sendable {
    public let image: CGImage
    public let geometry: WindowGeometry
}

/// Captures the iPhone Mirroring window.
///
/// Primary path is ScreenCaptureKit's screenshot API with a
/// desktop-independent window filter — unlike `screencapture -l` it works
/// even when the window is occluded or on another macOS Space, so capture
/// never needs to steal focus. Falls back to the `screencapture` CLI when
/// SCK fails for a reason other than missing permission.
public enum MirrorCapture {
    public static func capture(windowInfo: MirrorWindowInfo) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw MirrorError.screenRecordingDenied()
        }
        // ScreenCaptureKit fails transiently under sustained capture load
        // (SCStreamErrorDomain -3811 "audio/video capture failure", observed
        // live 2026-08-13 after many back-to-back captures). One short-backoff
        // retry absorbs that; a real failure (window gone, session torn down)
        // fails both attempts and moves on to the CLI.
        var sckError: Error?
        for attempt in 0..<2 {
            do {
                return try await captureWithSCK(windowInfo: windowInfo)
            } catch {
                sckError = error
                if attempt == 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
        }
        // Permission was already preflighted above, so any SCK failure
        // (including its window lookup missing) is worth the CLI fallback.
        FileHandle.standardError.write(Data("SCK capture failed (\(sckError.map(String.init(describing:)) ?? "?")); falling back to screencapture CLI\n".utf8))
        do {
            return try await captureWithCLI(windowInfo: windowInfo)
        } catch {
            // Both engines failed. Surface both causes — the raw CLI error
            // alone ("<tmpfile> couldn't be read") is useless to act on.
            throw MirrorError(
                "Capturing the mirroring window failed on both engines. "
                + "ScreenCaptureKit: \(sckError.map(String.init(describing:)) ?? "unknown"). "
                + "screencapture CLI: \(error).",
                remediation: "Usually transient under heavy capture load — retry the call. "
                + "If it persists, check that the mirroring session is connected (status tool) "
                + "and that Screen Recording permission is granted to the app hosting this server."
            )
        }
    }

    static func captureWithSCK(windowInfo: MirrorWindowInfo) async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let scWindow = content.windows.first { window in
            if windowInfo.windowID != 0 {
                return window.windowID == windowInfo.windowID
            }
            // Both dimensions: the app owns 1512×33 phantom windows that a
            // width-only filter matches, capturing a blank strip.
            return window.owningApplication?.bundleIdentifier == MirrorWindowBridge.bundleID
                && MirrorWindowBridge.isUsableWindowSize(
                    width: window.frame.width, height: window.frame.height)
        }
        guard let scWindow else {
            throw MirrorError("ScreenCaptureKit could not find the iPhone Mirroring window (id \(windowInfo.windowID)).")
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(scWindow.frame.width * scale))
        configuration.height = max(1, Int(scWindow.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        let geometry = WindowGeometry(
            windowID: windowInfo.windowID,
            boundsPoints: windowInfo.bounds,
            imagePixelSize: CGSize(width: image.width, height: image.height)
        )
        return CaptureResult(image: image, geometry: geometry)
    }

    /// `screencapture -l` fallback. Cannot capture cross-Space windows, so
    /// the caller should have activated the app when this path is likely.
    static func captureWithCLI(windowInfo: MirrorWindowInfo) async throws -> CaptureResult {
        let path = NSTemporaryDirectory() + "iphone-mirror-mcp-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let arguments: [String]
        if windowInfo.windowID != 0 {
            arguments = ["-l", String(windowInfo.windowID), "-x", "-o", path]
        } else {
            let b = windowInfo.bounds
            arguments = ["-R", "\(Int(b.origin.x)),\(Int(b.origin.y)),\(Int(b.width)),\(Int(b.height))", "-x", path]
        }
        let result = try await ProcessRunner.run("/usr/sbin/screencapture", arguments, timeout: 10)
        guard result.succeeded, let data = FileManager.default.contents(atPath: path),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(pngDataProviderSource: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw MirrorError(
                "screencapture failed (exit \(result.exitCode)): \(result.stderr)",
                remediation: captureRemediation(permissionGranted: CGPreflightScreenCaptureAccess())
            )
        }
        let geometry = WindowGeometry(
            windowID: windowInfo.windowID,
            boundsPoints: windowInfo.bounds,
            imagePixelSize: CGSize(width: image.width, height: image.height)
        )
        return CaptureResult(image: image, geometry: geometry)
    }

    /// Starts a DETACHED `screencapture -v` recording of the window region —
    /// the caller keeps driving the phone while it runs and stops it with
    /// SIGINT (screencapture finalizes the .mov on interrupt).
    public static func startRecordingProcess(
        windowInfo: MirrorWindowInfo, outputPath: String?
    ) throws -> (process: Process, path: String) {
        let path = outputPath ?? NSTemporaryDirectory()
            + "iphone-mirror-recording-\(Int(Date().timeIntervalSince1970)).mov"
        let b = windowInfo.bounds
        let region = "\(Int(b.origin.x)),\(Int(b.origin.y)),\(Int(b.width)),\(Int(b.height))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-R", region, "-x", path]
        do { try process.run() } catch {
            throw MirrorError("Could not start screencapture: \(error)")
        }
        return (process, path)
    }

    /// Records the window region to a .mov via `screencapture -v` for a fixed
    /// duration. Returns the output path.
    public static func record(
        windowInfo: MirrorWindowInfo, seconds: Int, outputPath: String?
    ) async throws -> String {
        let path = outputPath ?? NSTemporaryDirectory()
            + "iphone-mirror-recording-\(Int(Date().timeIntervalSince1970)).mov"
        let duration = min(max(seconds, 1), 600)
        // -v records video; -V sets fixed capture duration; -R limits to the
        // window's region (-l is not supported for video on all versions).
        let b = windowInfo.bounds
        let region = "\(Int(b.origin.x)),\(Int(b.origin.y)),\(Int(b.width)),\(Int(b.height))"
        let result = try await ProcessRunner.run(
            "/usr/sbin/screencapture",
            ["-v", "-V", String(duration), "-R", region, "-x", path],
            timeout: TimeInterval(duration + 30)
        )
        guard FileManager.default.fileExists(atPath: path) else {
            throw MirrorError(
                "Screen recording produced no file (exit \(result.exitCode)): \(result.stderr)",
                remediation: captureRemediation(permissionGranted: CGPreflightScreenCaptureAccess())
            )
        }
        return path
    }

    /// A capture failure with the permission GRANTED is almost always a
    /// transient window-server condition (window mid-transition, Space
    /// switch, session pause) — blaming the permission sends the caller to
    /// System Settings for nothing. Only blame it when it is actually missing.
    static func captureRemediation(permissionGranted: Bool) -> String {
        if permissionGranted {
            return "Screen Recording is granted, so this is usually transient (window mid-transition, Space switch, or the session pausing). Retry; if it persists, check the session with the status tool."
        }
        return "Check Screen Recording permission for the app hosting this MCP server."
    }
}
