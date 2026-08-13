import Foundation

/// Runs `operation`; when it throws, waits `delayNs` and tries exactly once
/// more (attempt is 0, then 1). The second failure propagates.
///
/// Exists for transient window-server conditions — a window that vanishes
/// from CGWindowList mid-transition, a capture that races a Space switch —
/// where one immediate retry succeeds and erroring at the tool boundary
/// would misdirect the caller.
public func withOneRetry<T>(
    delayNs: UInt64, _ operation: (_ attempt: Int) async throws -> T
) async rethrows -> T {
    do {
        return try await operation(0)
    } catch {
        try? await Task.sleep(nanoseconds: delayNs)
        return try await operation(1)
    }
}
