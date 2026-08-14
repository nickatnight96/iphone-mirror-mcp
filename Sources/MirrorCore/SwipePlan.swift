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

/// Plans the frame-by-frame deltas of a synthesized trackpad swipe.
///
/// iPhone Mirroring ignores bare scroll-wheel events; it honors only
/// trackpad-style continuous scrolls carrying gesture phases. This planner
/// produces the delta schedule; `script(for:)` wraps it in those phases.
///
/// ## Model
///
/// The gesture is a **moving finger sampled at the event frame rate**: a
/// position curve is evaluated at each frame boundary and the emitted deltas
/// are the *differences between successive samples*. Conservation of the
/// requested displacement is therefore structural — the differences of a
/// rounded position curve telescope to exactly its endpoint — rather than
/// something a reconciliation pass has to restore.
///
/// Two regimes, separated by whether the finger is still travelling when it
/// leaves the glass:
///
/// - **Drag** (slow) — the finger moves at a steady speed and has stopped by
///   the lift, so no inertia follows. Position is linear in time.
/// - **Flick** (fast) — the finger accelerates and is still moving at the
///   lift, so iOS carries the content on under exponential deceleration.
///   Position is quadratic during contact, then follows the decay integral.
///
/// For a flick, the split between contact travel and inertial travel is *not*
/// a tuned ratio. It falls out of integrating the velocity profile: contact
/// contributes `T/2` and inertia contributes the decay time constant `τ`, so
/// contact takes `T/2 / (T/2 + τ)` of the distance. Both phases are sampled
/// from one continuous curve, which keeps velocity continuous across the lift
/// — a discontinuity there reads as two gestures and the content jerks.
public enum SwipePlan {

    // MARK: - Constants

    /// Wheel units emitted per screen point of requested travel. Phased
    /// (continuous) scroll events displace content less per unit than legacy
    /// wheel events; measured against the live mirroring window.
    ///
    /// Unit note: distances entering `plan` are SCREEN POINTS — the window
    /// coordinate space CGEvents use — not retina pixels. `MirrorInput`
    /// converts tool pixel coordinates to points before planning.
    public static let wheelUnitsPerPoint = 3.0

    /// Mean speed (points/second) at or above which the finger is treated as
    /// still moving at the lift, earning an inertial tail. Below it the
    /// gesture is a deliberate drag-scroll.
    public static let flickMeanVelocity = 500.0

    /// Fraction of velocity retained per millisecond of inertial travel.
    /// Parameterized per *millisecond* — the same way Apple parameterizes
    /// scroll-view deceleration — so the tail's shape in real time is
    /// unchanged if frame pacing ever changes.
    public static let velocityRetainedPerMs = 0.996

    /// Event frame period (~60fps).
    public static let frameMs = 16

    /// Contact frames emitted even for an instantaneous gesture.
    public static let minimumDragFrames = 5

    /// Hard bound on inertial frames. The tail normally ends well before
    /// this, when the remaining travel stops rounding to a whole wheel unit.
    public static let momentumMaxFrames = 180

    /// Inertial time constant τ (milliseconds): the decay integral
    /// `∫₀^∞ r^u du = -1/ln r`. The distance a flick coasts is the lift
    /// velocity times this.
    static var inertialTimeConstantMs: Double {
        -1.0 / Foundation.log(velocityRetainedPerMs)
    }

    // MARK: - Phase field values (kCGScrollPhase / kCGMomentumScrollPhase)

    public static let phaseMayBegin: Int64 = 128
    public static let phaseBegan: Int64 = 1
    public static let phaseChanged: Int64 = 2
    public static let phaseEnded: Int64 = 4
    public static let momentumBegin: Int64 = 1
    public static let momentumContinue: Int64 = 2
    public static let momentumEnd: Int64 = 3

    public struct Plan: Equatable, Sendable {
        /// Frames posted while the finger is down (scroll phase Began/Changed).
        public let drag: [ScrollFrame]
        /// Frames posted after the lift (momentum phases). Empty for slow swipes.
        public let momentum: [ScrollFrame]
    }

    // MARK: - Planning

    /// Plans a swipe covering (`deltaX`, `deltaY`) points over `durationMs`.
    /// Total displacement is conserved exactly across drag + momentum.
    public static func plan(deltaX: Double, deltaY: Double, durationMs: Int) -> Plan {
        let contactMs = Double(max(durationMs, 1))
        let dragFrames = max(minimumDragFrames, durationMs / frameMs)

        let totalHorizontal = clampToWheelRange(deltaX * wheelUnitsPerPoint)
        let totalVertical = clampToWheelRange(deltaY * wheelUnitsPerPoint)

        let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()
        let meanVelocity = distance / (contactMs / 1000.0)

        // Drag: steady speed, at rest by the lift. Progress is linear, so the
        // curve is just the frame index over the frame count.
        guard meanVelocity.isFinite, meanVelocity >= flickMeanVelocity else {
            let progress = (1...dragFrames).map { Double($0) / Double(dragFrames) }
            return Plan(
                drag: quantize(progress: progress, horizontal: totalHorizontal, vertical: totalVertical),
                momentum: []
            )
        }

        // Flick: one continuous curve spanning contact and inertia.
        //
        //   contact travel  = v_peak · T/2          (velocity ramps 0 → v_peak)
        //   inertial travel = v_peak · τ            (τ = -1/ln r)
        //
        // Normalizing total travel to 1 gives v_peak = 1/(T/2 + τ), hence:
        let tau = inertialTimeConstantMs
        let halfContact = contactMs / 2
        let contactShare = halfContact / (halfContact + tau)
        let inertialShare = 1 - contactShare

        var progress: [Double] = []
        progress.reserveCapacity(dragFrames + momentumMaxFrames)

        // Contact: velocity ramps linearly, so position is quadratic in time.
        for frame in 1...dragFrames {
            let fraction = Double(frame) / Double(dragFrames)
            progress.append(contactShare * fraction * fraction)
        }

        // Inertia: position follows the decay integral. The tail ENDS when a
        // frame stops carrying a whole wheel unit — past that the decay is
        // still mathematically alive but quantizes to a dribble of
        // 1,0,1,0,0,1… units, which reads as stuttering rather than coasting.
        // Solving `travel-per-frame == ½ unit` for the elapsed time gives the
        // frame where that happens; see `inertialFrameCount`.
        let inertialUnits = (Double(totalHorizontal) * Double(totalHorizontal)
            + Double(totalVertical) * Double(totalVertical)).squareRoot() * inertialShare
        let tailFrames = inertialFrameCount(inertialUnits: inertialUnits)

        // Normalize by the decay actually consumed over that span so the
        // curve lands exactly on 1 at the final frame. Without this the
        // asymptote strands a fraction of the travel past the end and the
        // quantizer emits it as a lone unit after a run of dead frames.
        let consumed = 1 - Foundation.pow(velocityRetainedPerMs, Double(tailFrames * frameMs))
        if tailFrames > 0, consumed > 0 {
            for frame in 1...tailFrames {
                let elapsedMs = Double(frame * frameMs)
                let decayed = 1 - Foundation.pow(velocityRetainedPerMs, elapsedMs)
                progress.append(contactShare + inertialShare * (decayed / consumed))
            }
        } else {
            progress.append(1.0)
        }

        let frames = quantize(progress: progress, horizontal: totalHorizontal, vertical: totalVertical)
        let drag = Array(frames[..<dragFrames])
        var momentum = Array(frames[dragFrames...])
        // Trim the dead tail: once travel no longer rounds to a whole wheel
        // unit, further frames carry nothing.
        while let last = momentum.last, last.isZero { momentum.removeLast() }
        return Plan(drag: drag, momentum: momentum)
    }

    /// How many frames of inertia are worth emitting for a tail carrying
    /// `inertialUnits` of travel.
    ///
    /// Travel in the frame at elapsed `u` is `inertialUnits · r^u · (1 - r^h)`.
    /// Setting that to half a wheel unit — the point below which frames stop
    /// rounding to anything — and solving for `u` gives the last frame that
    /// still moves the content:
    ///
    ///     r^u = ½ / (inertialUnits · (1 - r^h))
    ///     u   = ln(that) / ln(r)
    ///
    /// Clamped to the hard frame bound, and to zero for a flick too small to
    /// coast at all.
    static func inertialFrameCount(inertialUnits: Double) -> Int {
        let perFrameAtLift = inertialUnits * (1 - Foundation.pow(velocityRetainedPerMs, Double(frameMs)))
        guard perFrameAtLift.isFinite, perFrameAtLift > 0.5 else { return 0 }
        let elapsedMs = Foundation.log(0.5 / perFrameAtLift) / Foundation.log(velocityRetainedPerMs)
        guard elapsedMs.isFinite, elapsedMs > 0 else { return 0 }
        return min(momentumMaxFrames, max(1, Int((elapsedMs / Double(frameMs)).rounded())))
    }

    /// Samples a cumulative progress curve into integer per-frame deltas.
    ///
    /// `progress` is the fraction of total travel completed at each frame
    /// boundary, ending at 1. Each delta is the change in the *rounded*
    /// position, so the deltas telescope to exactly the total and quantization
    /// error never accumulates.
    static func quantize(progress: [Double], horizontal: Int32, vertical: Int32) -> [ScrollFrame] {
        var frames: [ScrollFrame] = []
        frames.reserveCapacity(progress.count)
        var placedH: Int32 = 0
        var placedV: Int32 = 0
        for fraction in progress {
            let positionH = Int32((Double(horizontal) * fraction).rounded())
            let positionV = Int32((Double(vertical) * fraction).rounded())
            frames.append(ScrollFrame(vertical: positionV - placedV, horizontal: positionH - placedH))
            placedH = positionH
            placedV = positionV
        }
        return frames
    }

    /// Saturating Double→Int32. A plain conversion TRAPS on non-finite or
    /// out-of-range values, and the travel distance is caller-controlled.
    static func clampToWheelRange(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        if value >= Double(Int32.max) { return Int32.max }
        if value <= Double(Int32.min) { return Int32.min }
        return Int32(value)
    }

    // MARK: - Phase script

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
}
