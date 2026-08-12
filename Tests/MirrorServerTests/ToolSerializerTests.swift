import XCTest
@testable import MirrorServer

final class ToolSerializerTests: XCTestCase {
    /// Concurrent runs must be mutually exclusive and all complete.
    func testMutualExclusionUnderConcurrency() async throws {
        let serializer = ToolSerializer()
        actor Probe {
            var active = 0
            var maxActive = 0
            var completed = 0
            func enter() { active += 1; maxActive = max(maxActive, active) }
            func exit() { active -= 1; completed += 1 }
        }
        let probe = Probe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await serializer.run {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await probe.exit()
                        return true
                    }
                }
            }
            try await group.waitForAll()
        }
        let maxActive = await probe.maxActive
        let completed = await probe.completed
        XCTAssertEqual(maxActive, 1, "two tool bodies overlapped")
        XCTAssertEqual(completed, 8)
    }

    /// A failing body must not poison the queue for the next call.
    func testErrorDoesNotPoisonQueue() async throws {
        let serializer = ToolSerializer()
        struct Boom: Error {}
        do {
            _ = try await serializer.run { () async throws -> Int in throw Boom() }
            XCTFail("expected throw")
        } catch {}
        let value = try await serializer.run { 42 }
        XCTAssertEqual(value, 42)
    }

    func testReturnsBodyValue() async throws {
        let serializer = ToolSerializer()
        let value = try await serializer.run { "hello" }
        XCTAssertEqual(value, "hello")
    }
}
