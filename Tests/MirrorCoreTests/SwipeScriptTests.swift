import XCTest
@testable import MirrorCore

/// Invariants of `SwipePlan.script(for:)`, the full phase sequence a swipe
/// posts. A truncated sequence (missing lift or momentum close) leaves iOS
/// tracking a phantom finger: SpringBoard wedges mid-transition and drops all
/// further input until the mirroring app restarts — observed live in the
/// 2026-08-12 shakedown. These tests pin the termination guarantees.
final class SwipeScriptTests: XCTestCase {
    /// 120 pts over 2s = 60 pts/s, well under the 500 pts/s flick threshold.
    private var slowPlan: SwipePlan.Plan { SwipePlan.plan(deltaX: 0, deltaY: 120, durationMs: 2000) }
    /// 400 pts over 200ms = 2000 pts/s, well over the flick threshold.
    private var flickPlan: SwipePlan.Plan { SwipePlan.plan(deltaX: 0, deltaY: -400, durationMs: 200) }

    func testScriptStartsWithZeroDeltaMayBeginPrime() {
        for plan in [slowPlan, flickPlan] {
            let first = SwipePlan.script(for: plan)[0]
            XCTAssertEqual(first.scrollPhase, SwipePlan.phaseMayBegin)
            XCTAssertEqual(first.momentumPhase, 0)
            XCTAssertTrue(first.frame.isZero)
        }
    }

    func testDragPhasesAreBeganThenChanged() {
        let plan = slowPlan
        let script = SwipePlan.script(for: plan)
        let drag = script[1...plan.drag.count]
        XCTAssertEqual(drag.first?.scrollPhase, SwipePlan.phaseBegan)
        for step in drag.dropFirst() {
            XCTAssertEqual(step.scrollPhase, SwipePlan.phaseChanged)
        }
        XCTAssertTrue(drag.allSatisfy { $0.momentumPhase == 0 })
    }

    func testLiftAlwaysImmediatelyFollowsDrag() {
        for plan in [slowPlan, flickPlan] {
            let script = SwipePlan.script(for: plan)
            let lift = script[plan.drag.count + 1]
            XCTAssertEqual(lift.scrollPhase, SwipePlan.phaseEnded)
            XCTAssertEqual(lift.momentumPhase, 0)
            XCTAssertTrue(lift.frame.isZero, "the finger lift must carry zero deltas")
        }
    }

    func testSlowSwipeHasNoMomentumAndEndsAtLift() {
        let plan = slowPlan
        XCTAssertTrue(plan.momentum.isEmpty, "test premise: a slow swipe plans no momentum")
        let script = SwipePlan.script(for: plan)
        XCTAssertEqual(script.count, plan.drag.count + 2)  // prime + drag + lift
        XCTAssertEqual(script.last?.scrollPhase, SwipePlan.phaseEnded)
        XCTAssertTrue(script.allSatisfy { $0.momentumPhase == 0 })
    }

    func testFlickMomentumBeginsContinuesAndCloses() throws {
        let plan = flickPlan
        XCTAssertFalse(plan.momentum.isEmpty, "test premise: a flick plans a momentum tail")
        let script = SwipePlan.script(for: plan)
        let momentum = script[(plan.drag.count + 2)...]
        XCTAssertEqual(momentum.first?.momentumPhase, SwipePlan.momentumBegin)
        for step in momentum.dropFirst().dropLast() {
            XCTAssertEqual(step.momentumPhase, SwipePlan.momentumContinue)
        }
        let close = try XCTUnwrap(momentum.last)
        XCTAssertEqual(close.momentumPhase, SwipePlan.momentumEnd)
        XCTAssertTrue(close.frame.isZero, "the momentum close must carry zero deltas")
        XCTAssertTrue(momentum.allSatisfy { $0.scrollPhase == 0 })
    }

    func testNoStepCarriesBothScrollAndMomentumPhase() {
        for plan in [slowPlan, flickPlan] {
            for step in SwipePlan.script(for: plan) {
                XCTAssertFalse(step.scrollPhase != 0 && step.momentumPhase != 0,
                               "a step must be in the drag phase XOR the momentum phase")
            }
        }
    }

    func testScriptConservesPlanDisplacementExactly() {
        for plan in [slowPlan, flickPlan] {
            let script = SwipePlan.script(for: plan)
            let planVertical = (plan.drag + plan.momentum).reduce(Int64(0)) { $0 + Int64($1.vertical) }
            let scriptVertical = script.reduce(Int64(0)) { $0 + Int64($1.frame.vertical) }
            XCTAssertEqual(scriptVertical, planVertical,
                           "prime/lift/close must not add or lose displacement")
        }
    }

    /// The termination invariant across a broad input grid: every script ends
    /// its phases — exactly one lift, and a momentum tail iff it is closed.
    func testEveryScriptTerminatesItsPhases() {
        for deltaY in [-2000.0, -300.0, -10.0, 0.0, 10.0, 300.0, 2000.0] {
            for deltaX in [-500.0, 0.0, 500.0] {
                for durationMs in [1, 50, 300, 2000, 60_000] {
                    let plan = SwipePlan.plan(deltaX: deltaX, deltaY: deltaY, durationMs: durationMs)
                    let script = SwipePlan.script(for: plan)
                    let lifts = script.filter { $0.scrollPhase == SwipePlan.phaseEnded }
                    XCTAssertEqual(lifts.count, 1, "exactly one finger lift (dX=\(deltaX) dY=\(deltaY) ms=\(durationMs))")
                    let hasMomentum = script.contains { $0.momentumPhase != 0 }
                    if hasMomentum {
                        XCTAssertEqual(script.last?.momentumPhase, SwipePlan.momentumEnd,
                                       "a momentum tail must close (dX=\(deltaX) dY=\(deltaY) ms=\(durationMs))")
                    } else {
                        XCTAssertEqual(script.last?.scrollPhase, SwipePlan.phaseEnded)
                    }
                }
            }
        }
    }
}
