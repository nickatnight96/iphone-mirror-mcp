import CoreGraphics
import Foundation

/// Posts synthetic HID input to the iPhone Mirroring window.
///
/// Everything posts at `.cghidEventTap`: iPhone Mirroring ignores events
/// posted to its PID — it requires HID-level posting, with the app frontmost.
/// Gesture mechanics (scroll phases, momentum, flagsChanged modifiers) follow
/// the behavior the mirroir-mcp project reverse-engineered from real trackpad
/// traces; bare scroll events or key events with only flag bits set are
/// silently ignored by the mirroring session.
public enum MirrorInput {
    // Timing (microseconds).
    static let clickHoldUs: UInt32 = 60_000
    static let doubleTapGapUs: UInt32 = 50_000
    static let keyEventGapUs: UInt32 = 8_000
    static let interKeystrokeUs: UInt32 = 12_000
    static let warpSettleUs: UInt32 = 100_000
    static let momentumFrameUs: UInt32 = 16_000

    // Private CGEventField raw values for trackpad-style scrolls.
    static let fieldIsContinuous = CGEventField(rawValue: 88)!
    static let fieldPointDeltaAxis1 = CGEventField(rawValue: 96)!
    static let fieldPointDeltaAxis2 = CGEventField(rawValue: 97)!
    static let fieldScrollPhase = CGEventField(rawValue: 99)!
    static let fieldMomentumPhase = CGEventField(rawValue: 123)!

    /// How close (screen points) the cursor must land to the gesture point
    /// before scroll events are trusted to route into the mirroring window.
    static let cursorPlacementTolerance: CGFloat = 3

    /// Clamp caller-supplied durations so UInt32 microsecond math cannot trap.
    static func clampDurationMs(_ ms: Int) -> Int { min(max(ms, 1), 60_000) }

    private static func mouseEvent(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)
    }

    private static func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }

    /// Hide the cursor and detach it from the physical mouse for the duration
    /// of an operation, so the user's real mouse movement can't hijack an
    /// in-flight gesture (a mid-gesture routing change sends the tail into a
    /// different window and leaves iOS tracking a phantom finger).
    private static func withHiddenCursor<T>(_ body: () -> T) -> T {
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        return body()
    }

    /// Move the REAL cursor to `point` and verify it landed. Scroll gestures
    /// are routed by the window server to the window under the physical
    /// cursor — the location field on the posted events is not consulted —
    /// so an unverified warp silently sends the whole gesture into whatever
    /// window happens to be under the pointer.
    ///
    /// Must run BEFORE the cursor is disassociated from the mouse: position
    /// changes while disassociated are not reliably applied.
    /// After the cursor lands in the mirroring window, iPhone Mirroring
    /// plays a pointer-integration transition; input posted during it is
    /// dropped. Observed live 2026-08-12/13: click streams failed at 100ms
    /// and 300ms settles; the verified-working recipe uses 500ms (after the
    /// activation layer has already absorbed the window's unhide animation).
    static let cursorEntrySettleUs: UInt32 = 500_000
    static let cursorMarchSteps = 25
    static let cursorMarchFrameUs: UInt32 = 8_000

    /// How far the delta-march may land from its target and still count as
    /// DELIVERED: integer delta rounding drifts up to steps/2 points (12.5),
    /// plus slack. Distinct from cursorPlacementTolerance, which is the
    /// final post-pin requirement.
    static let marchDeliveryTolerance: CGFloat = 20

    /// Place the cursor at `point`, optionally approaching THROUGH an
    /// engagement waypoint (the mirroring window's center).
    ///
    /// Two phases are required, not an optimization: when the cursor first
    /// crosses into the mirroring window, the app starts a pointer-
    /// engagement transition and DISCARDS movement deltas that arrive while
    /// it plays — a single march from outside ends with the app's internal
    /// pointer stuck near the window edge it entered from, and the click
    /// then resolves there (observed live 2026-08-13: a tap on the fourth
    /// icon column opened the first-column app; the second attempt, with
    /// the cursor already engaged inside the window, landed exactly).
    /// Marching to the waypoint first absorbs the engagement, so the
    /// waypoint→target march is delivered entirely post-engagement.
    static func placeCursor(at point: CGPoint, through waypoint: CGPoint? = nil) throws {
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        for attempt in 0..<3 {
            var start = CGEvent(source: nil)?.location ?? point
            if let waypoint,
               !cursorIsPlaced(current: start, target: waypoint, tolerance: engagementVicinity) {
                _ = marchCursor(from: start, to: waypoint)
                usleep(cursorEntrySettleUs)
                start = CGEvent(source: nil)?.location ?? waypoint
            }
            let delivered = marchCursor(from: start, to: point)
            // Engagement needs real movement AT the destination: a wiggle of
            // small delta moves around the target is what the verified
            // recipe uses — a march that merely arrives can leave the
            // internal pointer unengaged.
            wiggleCursor(around: point)
            // Let the pointer-integration transition finish, then make sure
            // the cursor is STILL there — the user's physical mouse can move
            // it during the settle (it is not disassociated yet here).
            usleep(cursorEntrySettleUs)
            if delivered,
               let settled = CGEvent(source: nil)?.location,
               cursorIsPlaced(current: settled, target: point, tolerance: cursorPlacementTolerance) {
                return
            }
            // A freshly spawned server can have its posted events silently
            // dropped for a moment while macOS settles post-event access —
            // back off briefly before re-marching.
            if attempt < 2 { usleep(250_000) }
        }
        throw MirrorError(
            "Synthetic input is not being delivered — the cursor did not respond to posted movement, so a click would be silently dropped (or land wherever the pointer happens to be).",
            remediation: "Retry in a moment: a freshly started server can need a beat before macOS accepts its events. If it persists, check the Accessibility permission for the app hosting this server and make sure nothing else is controlling the mouse.")
    }

    /// The waypoint leg is skipped only when the cursor is already
    /// essentially AT the waypoint (deep inside the window) — proximity to
    /// anything else, including the target, is no proof of engagement.
    static let engagementVicinity: CGFloat = 50

    /// Small circular delta-move pattern around a point — the movement the
    /// pointer-integration machinery needs to (re)engage at a location
    /// (part of the live-verified click recipe, 2026-08-13). Ends with an
    /// absolute move back to the point itself.
    private static func wiggleCursor(around point: CGPoint) {
        var previous = CGEvent(source: nil)?.location ?? point
        for i in 0..<12 {
            let angle = Double(i) * 0.6
            let next = CGPoint(x: point.x + CGFloat(cos(angle) * 15),
                               y: point.y + CGFloat(sin(angle) * 15))
            if let move = mouseEvent(.mouseMoved, at: next) {
                move.setIntegerValueField(.mouseEventDeltaX, value: Int64((next.x - previous.x).rounded()))
                move.setIntegerValueField(.mouseEventDeltaY, value: Int64((next.y - previous.y).rounded()))
                post(move)
            }
            previous = next
            usleep(12_000)
        }
        if let back = mouseEvent(.mouseMoved, at: point) { post(back) }
        CGWarpMouseCursorPosition(point)
    }

    /// iPhone Mirroring tracks its own internal pointer from movement
    /// DELTAS, like a physical mouse — a teleported cursor (warp, or
    /// zero-delta synthetic moves) leaves the internal pointer behind, and
    /// clicks then resolve at the INTERNAL position, not the event location
    /// (observed live 2026-08-12: clicks collapsed toward the window edge
    /// the cursor entered from, opening the wrong app). So: march in small
    /// steps with the delta fields populated.
    ///
    /// Returns whether the posted EVENTS demonstrably moved the cursor near
    /// the target. This must be read BEFORE the pin warp below runs — the
    /// warp moves the cursor without event delivery, so checking after it
    /// would report success even while every posted event is being silently
    /// dropped (observed live on a freshly spawned server), and the
    /// subsequent click would be dropped the same way.
    private static func marchCursor(from start: CGPoint, to end: CGPoint) -> Bool {
        var previous = start
        for step in 1...cursorMarchSteps {
            let t = CGFloat(step) / CGFloat(cursorMarchSteps)
            let next = CGPoint(x: start.x + (end.x - start.x) * t,
                               y: start.y + (end.y - start.y) * t)
            if let move = mouseEvent(.mouseMoved, at: next) {
                move.setIntegerValueField(.mouseEventDeltaX, value: Int64((next.x - previous.x).rounded()))
                move.setIntegerValueField(.mouseEventDeltaY, value: Int64((next.y - previous.y).rounded()))
                post(move)
            }
            previous = next
            usleep(cursorMarchFrameUs)
        }
        let delivered: Bool
        if let reached = CGEvent(source: nil)?.location {
            delivered = cursorIsPlaced(current: reached, target: end, tolerance: marchDeliveryTolerance)
        } else {
            delivered = false
        }
        // Pin the exact final position: when the system applies the integer
        // DELTAS rather than the absolute locations, rounding drifts the
        // march off-target by up to steps/2 points. The internal pointer has
        // already converged via the march; this tiny absolute correction
        // doesn't desync it.
        if let settle = mouseEvent(.mouseMoved, at: end) { post(settle) }
        CGWarpMouseCursorPosition(end)
        return delivered
    }

    static func cursorIsPlaced(current: CGPoint, target: CGPoint, tolerance: CGFloat) -> Bool {
        abs(current.x - target.x) <= tolerance && abs(current.y - target.y) <= tolerance
    }

    // MARK: - Pointing

    public static func tap(at point: CGPoint, through waypoint: CGPoint? = nil) throws {
        guard let down = mouseEvent(.leftMouseDown, at: point),
              let up = mouseEvent(.leftMouseUp, at: point) else {
            throw MirrorError("Could not create mouse events (is Accessibility permission granted?)")
        }
        // iPhone Mirroring drops pointer events while the physical cursor is
        // outside its window (observed live 2026-08-12: identical taps failed
        // with the cursor parked elsewhere and landed with it inside) — so
        // every pointer gesture places the cursor first, not just swipes.
        try placeCursor(at: point, through: waypoint)
        withHiddenCursor {
            post(down)
            usleep(clickHoldUs)
            post(up)
        }
    }

    public static func doubleTap(at point: CGPoint, through waypoint: CGPoint? = nil) throws {
        // Create every event up front so a creation failure throws instead
        // of silently reporting a tap that never happened.
        var pairs: [(down: CGEvent, up: CGEvent)] = []
        for clickState in Int64(1)...2 {
            guard let down = mouseEvent(.leftMouseDown, at: point),
                  let up = mouseEvent(.leftMouseUp, at: point) else {
                throw MirrorError("Could not create mouse events (is Accessibility permission granted?)")
            }
            down.setIntegerValueField(.mouseEventClickState, value: clickState)
            up.setIntegerValueField(.mouseEventClickState, value: clickState)
            pairs.append((down, up))
        }
        try placeCursor(at: point, through: waypoint)
        withHiddenCursor {
            for (index, pair) in pairs.enumerated() {
                post(pair.down)
                usleep(clickHoldUs)
                post(pair.up)
                if index == 0 { usleep(doubleTapGapUs) }
            }
        }
    }

    public static func longPress(at point: CGPoint, durationMs: Int, through waypoint: CGPoint? = nil) throws {
        let duration = clampDurationMs(durationMs)
        guard let down = mouseEvent(.leftMouseDown, at: point),
              let up = mouseEvent(.leftMouseUp, at: point) else {
            throw MirrorError("Could not create mouse events (is Accessibility permission granted?)")
        }
        try placeCursor(at: point, through: waypoint)
        withHiddenCursor {
            post(down)
            usleep(UInt32(duration) * 1000)
            post(up)
        }
    }

    /// Sustained mouse drag (icon rearrange, sliders, drag-and-drop) —
    /// distinct from swipe, which scrolls content.
    public static func drag(from start: CGPoint, to end: CGPoint, durationMs: Int, through waypoint: CGPoint? = nil) throws {
        let duration = clampDurationMs(durationMs)
        guard let down = mouseEvent(.leftMouseDown, at: start),
              let up = mouseEvent(.leftMouseUp, at: end) else {
            throw MirrorError("Could not create mouse events (is Accessibility permission granted?)")
        }
        try placeCursor(at: start, through: waypoint)
        withHiddenCursor {
            post(down)
            let steps = max(10, duration / 16)
            let stepDelay = UInt32(duration) * 1000 / UInt32(steps)
            var previous = start
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                    y: start.y + (end.y - start.y) * t)
                if let move = mouseEvent(.leftMouseDragged, at: point) {
                    // Delta fields drive the app's internal pointer — see
                    // marchCursor; zero-delta drags leave it behind.
                    move.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
                    move.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
                    post(move)
                }
                previous = point
                usleep(stepDelay)
            }
            post(up)
        }
    }

    /// Swipe = trackpad-style continuous scroll gesture posted at the
    /// midpoint. Content follows the finger: positive deltaY drags content
    /// down, negative deltaX drags content left.
    ///
    /// The phase sequence comes from `SwipePlan.script(for:)`, and every
    /// CGEvent is materialized BEFORE anything posts: a creation failure
    /// mid-gesture would cut the sequence short of its lift/close, leaving
    /// iOS tracking a phantom finger — SpringBoard wedges mid-transition and
    /// drops all further input until the mirroring app restarts.
    public static func swipe(from start: CGPoint, to end: CGPoint, durationMs: Int, through waypoint: CGPoint? = nil) throws {
        let duration = clampDurationMs(durationMs)
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let midpoint = CGPoint(x: start.x + deltaX / 2, y: start.y + deltaY / 2)
        let plan = SwipePlan.plan(deltaX: deltaX, deltaY: deltaY, durationMs: duration)
        let steps = SwipePlan.script(for: plan)

        var events: [CGEvent] = []
        events.reserveCapacity(steps.count)
        for step in steps {
            guard let event = scrollEvent(step.frame, at: midpoint) else {
                throw MirrorError("Could not create scroll events (is Accessibility permission granted?)")
            }
            event.setIntegerValueField(fieldScrollPhase, value: step.scrollPhase)
            event.setIntegerValueField(fieldMomentumPhase, value: step.momentumPhase)
            events.append(event)
        }

        // Route the gesture: scroll events follow the REAL cursor, so place
        // and verify it over the gesture point before detaching the mouse.
        try placeCursor(at: midpoint, through: waypoint)

        let stepDelay = UInt32(duration) * 1000 / UInt32(max(plan.drag.count, 1))
        withHiddenCursor {
            for (index, step) in steps.enumerated() {
                post(events[index])
                switch (step.scrollPhase, step.momentumPhase) {
                case (SwipePlan.phaseMayBegin, _):
                    // Prime settle: iPhone Mirroring silently drops scroll
                    // events after a focus switch until a MayBegin arrives.
                    usleep(warpSettleUs)
                case (SwipePlan.phaseBegan, _), (SwipePlan.phaseChanged, _):
                    usleep(stepDelay)
                default:
                    usleep(momentumFrameUs)
                }
            }
        }
    }

    private static func scrollEvent(_ frame: ScrollFrame, at location: CGPoint) -> CGEvent? {
        guard let scroll = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: frame.vertical, wheel2: frame.horizontal, wheel3: 0
        ) else { return nil }
        scroll.location = location
        scroll.setIntegerValueField(fieldIsContinuous, value: 1)
        scroll.setIntegerValueField(fieldPointDeltaAxis1, value: Int64(frame.vertical))
        scroll.setIntegerValueField(fieldPointDeltaAxis2, value: Int64(frame.horizontal))
        return scroll
    }

    // MARK: - Keyboard

    /// Modifier keycodes, pressed in this order and released in reverse.
    static let modifierKeys: [(flag: CGEventFlags, keycode: UInt16)] = [
        (.maskControl, 0x3B), (.maskAlternate, 0x3A),
        (.maskShift, 0x38), (.maskCommand, 0x37),
    ]

    static func eventFlags(for modifiers: KeyChord.Modifiers) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// Press one key with modifiers. iPhone Mirroring tracks modifier state
    /// from explicit flagsChanged events, not from the flag bits on key
    /// events — so modifiers are pressed and released as their own events
    /// around the keystroke, exactly like a physical keyboard.
    public static func pressKey(keyCode: UInt16, flags: CGEventFlags = []) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw MirrorError("Could not create keyboard events (is Accessibility permission granted?)")
        }
        let relevant = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        if !relevant.isEmpty { pressModifiers(relevant) }
        down.flags = flags
        up.flags = flags
        post(down)
        usleep(keyEventGapUs)
        post(up)
        if !relevant.isEmpty {
            usleep(keyEventGapUs)
            releaseModifiers(relevant)
        }
    }

    private static func pressModifiers(_ flags: CGEventFlags) {
        var accumulated = CGEventFlags()
        for (flag, keycode) in modifierKeys where flags.contains(flag) {
            accumulated.insert(flag)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true) else { continue }
            event.type = .flagsChanged
            event.flags = accumulated
            post(event)
            usleep(keyEventGapUs)
        }
    }

    private static func releaseModifiers(_ flags: CGEventFlags) {
        var remaining = flags
        for (flag, keycode) in modifierKeys.reversed() where remaining.contains(flag) {
            remaining.remove(flag)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else { continue }
            event.type = .flagsChanged
            event.flags = remaining
            post(event)
            usleep(keyEventGapUs)
        }
    }

    /// Types text key by key. Returns the characters that had no key mapping
    /// (emoji, CJK, accents) and were skipped.
    public static func typeText(_ text: String) throws -> String {
        var skipped = ""
        for segment in KeyTyping.segments(for: text) {
            guard segment.typeable else {
                skipped += segment.text
                continue
            }
            for character in segment.text {
                guard let key = KeyTyping.key(for: character) else {
                    skipped.append(character)
                    continue
                }
                try pressKey(keyCode: key.keyCode, flags: key.shift ? [.maskShift] : [])
                usleep(interKeystrokeUs)
            }
        }
        return skipped
    }
}
