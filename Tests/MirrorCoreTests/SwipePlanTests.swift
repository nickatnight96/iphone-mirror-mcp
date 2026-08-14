import XCTest
@testable import MirrorCore

/// Tests for the swipe trajectory planner. The planner samples a position
/// curve and emits differences, so the properties worth pinning are the
/// curve's: exact displacement conservation, the contact/inertia split
/// predicted by integrating the velocity profile, and velocity continuity
/// across the lift.
final class SwipePlanTests: XCTestCase {
    func total(_ frames: [ScrollFrame]) -> (v: Int, h: Int) {
        frames.reduce((0, 0)) { ($0.0 + Int($1.vertical), $0.1 + Int($1.horizontal)) }
    }

    // MARK: - Displacement conservation

    func testSlowSwipeHasNoMomentumAndConservesDistance() {
        // 100 pts over 1000ms = 100 pts/s → below the flick threshold.
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 100, durationMs: 1000)
        XCTAssertTrue(plan.momentum.isEmpty)
        let sum = total(plan.drag)
        XCTAssertEqual(sum.v, Int(100 * SwipePlan.wheelUnitsPerPoint))
        XCTAssertEqual(sum.h, 0)
        XCTAssertEqual(plan.drag.count, 1000 / SwipePlan.frameMs)
    }

    func testFlickHasMomentumTailAndConservesDistance() {
        // 400 pts over 200ms = 2000 pts/s → flick.
        let plan = SwipePlan.plan(deltaX: 0, deltaY: -400, durationMs: 200)
        XCTAssertFalse(plan.momentum.isEmpty)
        let sum = total(plan.drag)
        let momentumSum = total(plan.momentum)
        XCTAssertEqual(sum.v + momentumSum.v, Int(-400 * SwipePlan.wheelUnitsPerPoint))
        XCTAssertEqual(sum.h + momentumSum.h, 0)
        XCTAssertFalse(plan.momentum.last?.isZero ?? true, "the dead tail must be trimmed")
    }

    func testHorizontalSignsFollowPointDeltas() {
        let plan = SwipePlan.plan(deltaX: -300, deltaY: 0, durationMs: 100)
        let sum = total(plan.drag)
        let momentumSum = total(plan.momentum)
        XCTAssertEqual(sum.h + momentumSum.h, Int(-300 * SwipePlan.wheelUnitsPerPoint))
        XCTAssertEqual(sum.v + momentumSum.v, 0)
    }

    /// Conservation is structural, so it must hold across the whole input
    /// grid — including diagonals, where both axes quantize independently.
    func testDisplacementIsConservedAcrossInputGrid() {
        for deltaY in [-1200.0, -137.0, -1.0, 0.0, 1.0, 137.0, 1200.0] {
            for deltaX in [-450.0, -13.0, 0.0, 13.0, 450.0] {
                for durationMs in [1, 30, 200, 1500, 10_000] {
                    let plan = SwipePlan.plan(deltaX: deltaX, deltaY: deltaY, durationMs: durationMs)
                    let sum = total(plan.drag + plan.momentum)
                    XCTAssertEqual(
                        sum.v, Int(SwipePlan.clampToWheelRange(deltaY * SwipePlan.wheelUnitsPerPoint)),
                        "vertical (dX=\(deltaX) dY=\(deltaY) ms=\(durationMs))")
                    XCTAssertEqual(
                        sum.h, Int(SwipePlan.clampToWheelRange(deltaX * SwipePlan.wheelUnitsPerPoint)),
                        "horizontal (dX=\(deltaX) dY=\(deltaY) ms=\(durationMs))")
                }
            }
        }
    }

    // MARK: - Trajectory shape

    /// The contact/inertia split is predicted, not tuned: contact travel is
    /// `v_peak · T/2` and inertial travel is `v_peak · τ`, so contact should
    /// take `(T/2) / (T/2 + τ)` of the distance.
    func testContactInertiaSplitMatchesTheVelocityIntegral() {
        let durationMs = 200
        let plan = SwipePlan.plan(deltaX: 0, deltaY: -400, durationMs: durationMs)
        let dragTravel = Double(abs(total(plan.drag).v))
        let totalTravel = Double(abs(total(plan.drag + plan.momentum).v))

        let halfContact = Double(durationMs) / 2
        let expectedShare = halfContact / (halfContact + SwipePlan.inertialTimeConstantMs)
        // Tolerance covers integer quantization and the trimmed dead tail.
        XCTAssertEqual(dragTravel / totalTravel, expectedShare, accuracy: 0.02)
    }

    /// Contact velocity ramps from rest, so per-frame deltas must increase
    /// monotonically while the finger is down.
    func testFlickContactAcceleratesFromRest() {
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 600, durationMs: 320)
        let deltas = plan.drag.map { Int($0.vertical) }
        XCTAssertGreaterThan(deltas.count, 3)
        for (earlier, later) in zip(deltas, deltas.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier, "contact velocity must not drop: \(deltas)")
        }
        XCTAssertLessThan(deltas.first!, deltas.last!, "the finger must accelerate")
    }

    /// Inertia decays. Integer quantization lets adjacent frames jitter by a
    /// unit (…6, 5, 6, 4…), and once the tail is down to 1–2 units per frame
    /// that noise swamps the decay over any short window. So this pins decay
    /// where it is actually measurable — across frames still carrying several
    /// units — plus the whole-tail envelope.
    func testMomentumTailDecays() {
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 600, durationMs: 200)
        let deltas = plan.momentum.map { abs(Int($0.vertical)) }
        XCTAssertGreaterThan(deltas.count, 10)

        for (index, later) in deltas.enumerated().dropFirst(4) where deltas[index - 4] >= 4 {
            XCTAssertLessThanOrEqual(later, deltas[index - 4],
                                     "inertia must decay across frames: \(deltas)")
        }

        let quarter = deltas.count / 4
        let opening = deltas.prefix(quarter).reduce(0, +)
        let closing = deltas.suffix(quarter).reduce(0, +)
        XCTAssertGreaterThan(opening, closing * 4, "the tail's envelope must fall away: \(deltas)")
        XCTAssertEqual(deltas.max(), deltas.first, "inertia is fastest right after the lift")
    }

    /// The tail must not strand travel past the decay and emit it as a lone
    /// unit after a run of dead frames — that reads as a second flick. The
    /// planner trims trailing zeros, so a stranded unit shows up as a long
    /// zero run *before* the final frame, not after it.
    func testMomentumTailHasNoStrandedTerminalUnit() {
        for durationMs in [50, 120, 200, 400] {
            let plan = SwipePlan.plan(deltaX: 0, deltaY: 900, durationMs: durationMs)
            let deltas = plan.momentum.map { abs(Int($0.vertical)) }
            XCTAssertNotEqual(deltas.last, 0, "premise: the planner trims trailing zeros")
            var longestGap = 0, currentGap = 0
            for delta in deltas {
                currentGap = delta == 0 ? currentGap + 1 : 0
                longestGap = max(longestGap, currentGap)
            }
            XCTAssertLessThanOrEqual(longestGap, 3,
                                     "ms=\(durationMs) left a \(longestGap)-frame dead gap: \(deltas)")
        }
    }

    /// Both phases are sampled from one curve, so speed must not jump at the
    /// lift — a discontinuity there reads as two gestures and content jerks.
    func testVelocityIsContinuousAcrossTheLift() {
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 800, durationMs: 400)
        let lastContact = abs(Double(plan.drag.last!.vertical))
        let firstInertial = abs(Double(plan.momentum.first!.vertical))
        XCTAssertGreaterThan(lastContact, 0)
        // One frame of decay separates them; allow a little quantization slack.
        let expected = lastContact * Foundation.pow(
            SwipePlan.velocityRetainedPerMs, Double(SwipePlan.frameMs))
        XCTAssertEqual(firstInertial, expected, accuracy: max(1.5, expected * 0.15))
    }

    func testSlowSwipeTravelsAtSteadySpeed() {
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 240, durationMs: 2000)
        let deltas = plan.drag.map { Int($0.vertical) }
        // Linear progress quantizes to at most two adjacent integer values.
        XCTAssertLessThanOrEqual(Set(deltas).count, 2, "steady speed, got \(Set(deltas).sorted())")
    }

    // MARK: - Boundaries

    func testMinimumDragFrames() {
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 10, durationMs: 1)
        XCTAssertGreaterThanOrEqual(plan.drag.count, SwipePlan.minimumDragFrames)
    }

    func testZeroDistanceProducesNoTravel() {
        let plan = SwipePlan.plan(deltaX: 0, deltaY: 0, durationMs: 300)
        XCTAssertTrue(plan.drag.allSatisfy(\.isZero))
        XCTAssertTrue(plan.momentum.isEmpty)
    }

    func testSaturationOnExtremeInput() {
        XCTAssertEqual(SwipePlan.clampToWheelRange(Double.infinity), 0)
        XCTAssertEqual(SwipePlan.clampToWheelRange(Double.nan), 0)
        XCTAssertEqual(SwipePlan.clampToWheelRange(1e12), Int32.max)
        XCTAssertEqual(SwipePlan.clampToWheelRange(-1e12), Int32.min)
        // Must not trap, and must still conserve the (saturated) total.
        let plan = SwipePlan.plan(deltaX: 1e11, deltaY: -1e11, durationMs: 100)
        XCTAssertFalse(plan.drag.isEmpty)
        let sum = total(plan.drag + plan.momentum)
        XCTAssertEqual(sum.v, Int(Int32.min))
        XCTAssertEqual(sum.h, Int(Int32.max))
    }

    func testNonFiniteDurationAndDistanceDoNotTrap() {
        let plan = SwipePlan.plan(deltaX: .nan, deltaY: .nan, durationMs: 0)
        XCTAssertFalse(plan.drag.isEmpty)
        XCTAssertTrue(plan.drag.allSatisfy(\.isZero))
    }

    // MARK: - Quantizer

    func testQuantizeTelescopesToTheExactTotal() {
        let progress = [0.1, 0.35, 0.6, 0.85, 1.0]
        let frames = SwipePlan.quantize(progress: progress, horizontal: -37, vertical: 100)
        XCTAssertEqual(frames.count, progress.count)
        XCTAssertEqual(frames.reduce(0) { $0 + Int($1.vertical) }, 100)
        XCTAssertEqual(frames.reduce(0) { $0 + Int($1.horizontal) }, -37)
    }

    func testQuantizeDoesNotAccumulateRoundingError() {
        // A total that divides unevenly across many frames: every prefix must
        // stay within one unit of the ideal position.
        let count = 97
        let progress = (1...count).map { Double($0) / Double(count) }
        let frames = SwipePlan.quantize(progress: progress, horizontal: 0, vertical: 1000)
        var running = 0
        for (index, frame) in frames.enumerated() {
            running += Int(frame.vertical)
            let ideal = 1000.0 * Double(index + 1) / Double(count)
            XCTAssertLessThanOrEqual(abs(Double(running) - ideal), 1.0)
        }
        XCTAssertEqual(running, 1000)
    }

    func testQuantizeHandlesEmptyCurve() {
        XCTAssertTrue(SwipePlan.quantize(progress: [], horizontal: 5, vertical: 5).isEmpty)
    }
}
