import XCTest
@testable import MirrorCore

final class SwipePlanTests: XCTestCase {
    func total(_ frames: [ScrollFrame]) -> (v: Int, h: Int) {
        frames.reduce((0, 0)) { ($0.0 + Int($1.vertical), $0.1 + Int($1.horizontal)) }
    }

    func testSlowSwipeHasNoMomentumAndConservesDistance() {
        // 100px over 1000ms = 100 px/s → below flick threshold.
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 100, durationMs: 1000)
        XCTAssertTrue(plan.momentum.isEmpty)
        let sum = total(plan.drag)
        XCTAssertEqual(sum.v, Int(100 * SwipePlan.scrollAmplification))
        XCTAssertEqual(sum.h, 0)
        XCTAssertEqual(plan.drag.count, 1000 / SwipePlan.frameMs)
    }

    func testFlickHasMomentumTailAndConservesDistance() {
        // 400px over 200ms = 2000 px/s → flick.
        let plan = SwipePlan.plan(deltaX: 0, deltaY: -400, durationMs: 200)
        XCTAssertFalse(plan.momentum.isEmpty)
        let sum = total(plan.drag)
        let momentumSum = total(plan.momentum)
        XCTAssertEqual(sum.v + momentumSum.v, Int(-400 * SwipePlan.scrollAmplification))
        XCTAssertEqual(sum.h + momentumSum.h, 0)
        // Momentum trims trailing zero frames.
        XCTAssertFalse(plan.momentum.last?.isZero ?? true)
    }

    func testHorizontalSignsFollowPixelDeltas() {
        let plan = SwipePlan.plan(deltaX: -300, deltaY: 0, durationMs: 100)
        let sum = total(plan.drag)
        let momentumSum = total(plan.momentum)
        XCTAssertEqual(sum.h + momentumSum.h, Int(-300 * SwipePlan.scrollAmplification))
        XCTAssertEqual(sum.v + momentumSum.v, 0)
    }

    func testMinimumDragFrames() {
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 10, durationMs: 1)
        XCTAssertGreaterThanOrEqual(plan.drag.count, SwipePlan.minimumDragFrames)
    }

    func testSaturationOnExtremeInput() {
        XCTAssertEqual(SwipePlan.saturatedDelta(Double.infinity), 0)
        XCTAssertEqual(SwipePlan.saturatedDelta(Double.nan), 0)
        XCTAssertEqual(SwipePlan.saturatedDelta(1e12), Int32.max)
        XCTAssertEqual(SwipePlan.saturatedDelta(-1e12), Int32.min)
        // Must not crash and must still conserve totals.
        let plan = SwipePlan.plan(deltaX: 1e11, deltaY: -1e11, durationMs: 100)
        XCTAssertFalse(plan.drag.isEmpty)
    }

    func testApportionSumsExactly() {
        let deltas = SwipePlan.apportion(total: 100, weights: [1, 2, 3, 4])
        XCTAssertEqual(deltas.reduce(0, +), 100)
        XCTAssertEqual(deltas.count, 4)
        // Weights are increasing, so deltas should be non-decreasing-ish.
        XCTAssertLessThan(deltas.first!, deltas.last!)
    }

    func testApportionZeroWeights() {
        XCTAssertEqual(SwipePlan.apportion(total: 50, weights: []), [])
        XCTAssertEqual(SwipePlan.apportion(total: 50, weights: [0, 0]), [0, 0])
    }
}
