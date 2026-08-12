import Foundation

/// Result of running an external process.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Runs external commands (xcodebuild, xcrun, open, …) with argument arrays —
/// never through a shell, so tool parameters cannot inject commands.
public enum ProcessRunner {
    /// Byte cap applied independently to stdout and stderr. Build logs can be
    /// enormous; when over the cap the middle is elided, keeping head and tail
    /// (errors usually cluster at the end of xcodebuild output).
    public static let defaultMaxOutputBytes = 400_000

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }
        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    public static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120,
        maxOutputBytes: Int = defaultMaxOutputBytes
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stdoutBuffer.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stderrBuffer.append(chunk) }
        }

        let timedOutFlag = Flag()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: MirrorError(
                    "Failed to launch \(executable): \(error.localizedDescription)"))
                return
            }
            // Watchdog: terminate, then force-kill if the process ignores SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                guard let process, process.isRunning else { return }
                timedOutFlag.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak process] in
                    guard let process, process.isRunning else { return }
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        // Drain anything still buffered in the pipes after termination.
        // Detach the readability handlers FIRST — readToEnd must not race a
        // still-attached handler on the same file handle.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutRemainder = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil
        if let stdoutRemainder { stdoutBuffer.append(stdoutRemainder) }
        let stderrRemainder = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
        if let stderrRemainder { stderrBuffer.append(stderrRemainder) }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: Self.truncated(stdoutBuffer.snapshot(), maxBytes: maxOutputBytes),
            stderr: Self.truncated(stderrBuffer.snapshot(), maxBytes: maxOutputBytes),
            timedOut: timedOutFlag.get()
        )
    }

    /// Keeps the first quarter and last three quarters of the byte budget,
    /// eliding the middle. Exposed for testing.
    public static func truncated(_ data: Data, maxBytes: Int) -> String {
        func decode(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
        guard data.count > maxBytes else { return decode(data) }
        let headBytes = maxBytes / 4
        let tailBytes = maxBytes - headBytes
        let head = decode(data.prefix(headBytes))
        let tail = decode(data.suffix(tailBytes))
        let elided = data.count - headBytes - tailBytes
        return head + "\n…[\(elided) bytes elided]…\n" + tail
    }
}
