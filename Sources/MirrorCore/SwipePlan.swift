import Foundation

/// One frame of a synthesized trackpad scroll gesture.
/// `vertical` maps to CGEvent wheel1, `horizontal` to wheel2.
public struct ScrollFrame: Equatable, Sendable {
    public let vertical: Int32
    public let horizontal: Int32
    public init(vertical: Int32, horizontal: Int32) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
    public var isZero: Bool { vertical == 0 && horizontal == 0 }
    public static let zero = ScrollFrame(vertical: 0, horizontal: 0)
}

/// One scroll event of a fully phased gesture: the deltas plus the scroll /
/// momentum phase fields it must carry. A gesture is a `[ScrollStep]` so the
/// entire sequence — including the terminating lift and momentum close — can
/// be materialized as CGEvents BEFORE anything posts.
public struct ScrollStep: Equatable, Sendable {
    public let frame: ScrollFrame
    public let scrollPhase: Int64
    public let momentumPhase: Int64
    public init(frame: ScrollFrame, scrollPhase: Int64, momentumPhase: Int64) {
        self.frame = frame
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
    }
}

/// Computes the frame-by-frame scroll deltas for a swipe gesture.
///
/// iPhone Mirroring ignores bare scroll-wheel events; it only honors
/// trackpad-style continuous scrolls with gesture phases. The shape here
/// mirrors a physical trackpad flick (technique learned from the mirroir-mcp
/// project's captured trackpad traces): drag frames ramp linearly to a peak
/// velocity while the finger is down, and fast flicks continue with a
/// geometrically decaying momentum tail after the lift, which iOS reads as a
/// native flick so paging surfaces snap correctly. Slow swipes are deliberate
/// drag-scrolls: uniform frames, no momentum.
public enum SwipePlan {
    /// Unit note: all distances here are SCREEN POINTS (the window coordinate
    /// space CGEvents use), not retina pixels — the amplification and flick
    /// threshold were tuned against point-space gestures, matching the
    /// mirroir-mcp reference. MirrorInput converts tool pixel coordinates to
    /// points before planning a swipe.
    ///
    /// Continuous-gesture events have smaller per-unit displacement than
    /// legacy wheel events; amplify to match physical trackpad distance.
    public static let scrollAmplification = 3.0
    /// Speed (points/second, pre-amplification) at which a swipe becomes a
    /// flick and receives a momentum tail.
    public static let flickVelocityThreshold = 500.0
    /// Per-frame decay of the momentum tail.
    public static let momentumDecayPerFrame = 0.94
    /// Momentum tail cap (~1.5s at 60fps); zero frames are trimmed anyway.
    public static let momentumMaxFrames = 90
    /// Frame pacing for the drag phase (~60fps).
    public static let frameMs = 16
    /// Minimum drag frames regardless of duration.
    public static let minimumDragFrames = 5

    public struct Plan: Equatable, Sendable {
        /// Frames posted while the finger is down (scroll phase Began/Changed).
        public let drag: [ScrollFrame]
        /// Frames posted after the lift (momentum phases). Empty for slow swipes.
        public let momentum: [ScrollFrame]
    }

    // Scroll phase values observed in real trackpad traces.
    public static let phaseMayBegin: Int64 = 128
    public static let phaseBegan: Int64 = 1
    public static let phaseChanged: Int64 = 2
    public static let phaseEnded: Int64 = 4
    public static let momentumBegin: Int64 = 1
    public static let momentumContinue: Int64 = 2
    public static let momentumEnd: Int64 = 3

    /// The complete, phase-correct event sequence for a plan:
    /// MayBegin prime → Began/Changed drag frames → zero-delta Ended lift →
    /// momentum Begin/Continue frames → zero-delta momentum End close
    /// (flicks only).
    ///
    /// INVARIANT: the sequence always terminates its phases — the lift always
    /// follows the drag, and a momentum tail is always closed. A gesture cut
    /// short (skipped lift/close) leaves iOS tracking a phantom finger:
    /// SpringBoard wedges mid-transition and drops ALL further input until
    /// the mirroring app restarts. Callers must post either the whole script
    /// or none of it.
    public static func script(for plan: Plan) -> [ScrollStep] {
        var steps: [ScrollStep] = []
        steps.reserveCapacity(plan.drag.count + plan.momentum.count + 3)
        steps.append(ScrollStep(frame: .zero, scrollPhase: phaseMayBegin, momentumPhase: 0))
        for (index, frame) in plan.drag.enumerated() {
            steps.append(ScrollStep(
                frame: frame,
                scrollPhase: index == 0 ? phaseBegan : phaseChanged,
                momentumPhase: 0))
        }
        steps.append(ScrollStep(frame: .zero, scrollPhase: phaseEnded, momentumPhase: 0))
        for (index, frame) in plan.momentum.enumerated() {
            steps.append(ScrollStep(
                frame: frame,
                scrollPhase: 0,
                momentumPhase: index == 0 ? momentumBegin : momentumContinue))
        }
        if !plan.momentum.isEmpty {
            steps.append(ScrollStep(frame: .zero, scrollPhase: 0, momentumPhase: momentumEnd))
        }
        return steps
    }

    /// Plans a swipe covering (`deltaX`, `deltaY`) pixels over `durationMs`.
    /// Total displacement is conserved exactly across drag + momentum.
    public static func plan(deltaX: Double, deltaY: Double, durationMs: Int) -> Plan {
        let dragCount = max(minimumDragFrames, durationMs / frameMs)
        let totalVertical = saturatedDelta(deltaY * scrollAmplification)
        let totalHorizontal = saturatedDelta(deltaX * scrollAmplification)

        let seconds = Double(max(durationMs, 1)) / 1000.0
        let velocity = (deltaX * deltaX + deltaY * deltaY).squareRoot() / seconds

        guard velocity >= flickVelocityThreshold else {
            let uniform = [Double](repeating: 1.0, count: dragCount)
            return Plan(
                drag: frames(vertical: totalVertical, horizontal: totalHorizontal, weights: uniform),
                momentum: []
            )
        }

        // Flick: one weight sequence across both phases keeps velocity
        // continuous at the lift and lets a single apportionment conserve
        // the total exactly.
        var weights: [Double] = []
        weights.reserveCapacity(dragCount + momentumMaxFrames)
        for frame in 1...dragCount { weights.append(Double(frame)) }
        var momentumWeight = Double(dragCount) * momentumDecayPerFrame
        for _ in 0..<momentumMaxFrames {
            weights.append(momentumWeight)
            momentumWeight *= momentumDecayPerFrame
        }

        let all = frames(vertical: totalVertical, horizontal: totalHorizontal, weights: weights)
        let drag = Array(all[..<dragCount])
        var momentum = Array(all[dragCount...])
        while let last = momentum.last, last.isZero { momentum.removeLast() }
        return Plan(drag: drag, momentum: momentum)
    }

    /// Saturating Double→Int32: a plain conversion traps on non-finite or
    /// out-of-range values, and tool input is caller-controlled.
    static func saturatedDelta(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        if value >= Double(Int32.max) { return Int32.max }
        if value <= Double(Int32.min) { return Int32.min }
        return Int32(value)
    }

    private static func frames(vertical: Int32, horizontal: Int32, weights: [Double]) -> [ScrollFrame] {
        let v = apportion(total: vertical, weights: weights)
        let h = apportion(total: horizontal, weights: weights)
        return zip(v, h).map { ScrollFrame(vertical: $0, horizontal: $1) }
    }

    /// Splits `total` into integer per-frame deltas proportional to `weights`;
    /// cumulative rounding guarantees the deltas sum exactly to `total`.
    static func apportion(total: Int32, weights: [Double]) -> [Int32] {
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return [Int32](repeating: 0, count: weights.count) }
        var deltas: [Int32] = []
        deltas.reserveCapacity(weights.count)
        var cumulative = 0.0
        var allocated: Int32 = 0
        for weight in weights {
            cumulative += weight
            let target = Int32((Double(total) * cumulative / weightSum).rounded())
            deltas.append(target - allocated)
            allocated = target
        }
        return deltas
    }
}
