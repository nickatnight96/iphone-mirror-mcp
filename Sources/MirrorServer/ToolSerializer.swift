import Foundation

/// Strict FIFO execution gate for mirroring tools.
///
/// MirrorSession is an actor, but actors are reentrant: every `await` inside
/// a tool body (screen capture, polling sleeps) is a suspension point where a
/// concurrently issued tool call could interleave — scrolling the screen
/// between another call's OCR read and its dependent tap, or overwriting the
/// shared last-screenshot size mid-flow. Routing every mirroring tool call
/// through this serializer makes each call atomic with respect to the others:
/// a call starts only after the previous one has fully finished.
public actor ToolSerializer {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            if let previous { await previous.value }
            return try await body()
        }
        // The stored tail only tracks completion; errors surface to the
        // caller below, never to the next queued call.
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
