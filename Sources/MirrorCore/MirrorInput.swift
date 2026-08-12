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

    // Scroll phase values observed in real trackpad traces.
    static let phaseMayBegin: Int64 = 128
    static let phaseBegan: Int64 = 1
    static let phaseChanged: Int64 = 2
    static let phaseEnded: Int64 = 4
    static let momentumBegin: Int64 = 1
    static let momentumContinue: Int64 = 2
    static let momentumEnd: Int64 = 3

    /// Clamp caller-supplied durations so UInt32 microsecond math cannot trap.
    static func clampDurationMs(_ ms: Int) -> Int { min(max(ms, 1), 60_000) }

    private static func mouseEvent(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)
    }

    private static func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }

    /// Hide the cursor and detach it from the physical mouse for the duration
    /// of an operation, so synthetic pointer movement doesn't fight the user.
    private static func withHiddenCursor<T>(warpTo point: CGPoint? = nil, _ body: () -> T) -> T {
        if let point { CGWarpMouseCursorPosition(point) }  // warp BEFORE hiding
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
        if point != nil { usleep(warpSettleUs) }
        defer {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        return body()
    }

    // MARK: - Pointing

    public static func tap(at point: CGPoint) throws {
        guard let down = mouseEvent(.leftMouseDown, at: point),
              let up = mouseEvent(.leftMouseUp, at: point) else {
            throw MirrorError("Could not create mouse events (is Accessibility permission granted?)")
        }
        withHiddenCursor {
            post(down)
            usleep(clickHoldUs)
            post(up)
        }
    }

    public static func doubleTap(at point: CGPoint) throws {
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
        withHiddenCursor {
            for (index, pair) in pairs.enumerated() {
                post(pair.down)
                usleep(clickHoldUs)
                post(pair.up)
                if index == 0 { usleep(doubleTapGapUs) }
            }
        }
    }

    public static func longPress(at point: CGPoint, durationMs: Int) throws {
        let duration = clampDurationMs(durationMs)
        guard let down = mouseEvent(.leftMouseDown, at: point),
              let up = mouseEvent(.leftMouseUp, at: point) else {
            throw MirrorError("Could not create mouse events (is Accessibility permission granted?)")
        }
        withHiddenCursor {
            post(down)
            usleep(UInt32(duration) * 1000)
            post(up)
        }
    }

    /// Sustained mouse drag (icon rearrange, sliders, drag-and-drop) —
    /// distinct from swipe, which scrolls content.
    public static func drag(from start: CGPoint, to end: CGPoint, durationMs: Int) throws {
        let duration = clampDurationMs(durationMs)
        guard let down = mouseEvent(.leftMouseDown, at: start),
              let up = mouseEvent(.leftMouseUp, at: end) else {
            throw MirrorError("Could not create mouse events (is Accessibility permission granted?)")
        }
        withHiddenCursor {
            post(down)
            let steps = max(10, duration / 16)
            let stepDelay = UInt32(duration) * 1000 / UInt32(steps)
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                    y: start.y + (end.y - start.y) * t)
                if let move = mouseEvent(.leftMouseDragged, at: point) { post(move) }
                usleep(stepDelay)
            }
            post(up)
        }
    }

    /// Swipe = trackpad-style continuous scroll gesture posted at the
    /// midpoint. Content follows the finger: positive deltaY drags content
    /// down, negative deltaX drags content left.
    public static func swipe(from start: CGPoint, to end: CGPoint, durationMs: Int) throws {
        let duration = clampDurationMs(durationMs)
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let midpoint = CGPoint(x: start.x + deltaX / 2, y: start.y + deltaY / 2)
        let plan = SwipePlan.plan(deltaX: deltaX, deltaY: deltaY, durationMs: duration)

        withHiddenCursor(warpTo: midpoint) {
            // Establish the cursor inside the window: after a focus switch the
            // warp alone may not register with the window's event tracking.
            if let move = mouseEvent(.mouseMoved, at: midpoint) {
                post(move)
                usleep(50_000)
            }
            // Prime the scroll subsystem: iPhone Mirroring silently drops
            // scroll events after a focus switch until a MayBegin arrives.
            if let prime = scrollEvent(ScrollFrame(vertical: 0, horizontal: 0), at: midpoint) {
                prime.setIntegerValueField(fieldScrollPhase, value: phaseMayBegin)
                prime.setIntegerValueField(fieldMomentumPhase, value: 0)
                post(prime)
                usleep(warpSettleUs)
            }
            let stepDelay = UInt32(duration) * 1000 / UInt32(max(plan.drag.count, 1))
            for (index, frame) in plan.drag.enumerated() {
                guard let scroll = scrollEvent(frame, at: midpoint) else { continue }
                scroll.setIntegerValueField(fieldScrollPhase, value: index == 0 ? phaseBegan : phaseChanged)
                scroll.setIntegerValueField(fieldMomentumPhase, value: 0)
                post(scroll)
                usleep(stepDelay)
            }
            // Finger lift: zero-delta phaseEnded, as in a physical trace.
            if let lift = scrollEvent(ScrollFrame(vertical: 0, horizontal: 0), at: midpoint) {
                lift.setIntegerValueField(fieldScrollPhase, value: phaseEnded)
                lift.setIntegerValueField(fieldMomentumPhase, value: 0)
                post(lift)
                usleep(momentumFrameUs)
            }
            // Momentum tail (flicks only) so iOS paging surfaces snap.
            for (index, frame) in plan.momentum.enumerated() {
                guard let scroll = scrollEvent(frame, at: midpoint) else { continue }
                scroll.setIntegerValueField(fieldScrollPhase, value: 0)
                scroll.setIntegerValueField(fieldMomentumPhase,
                                            value: index == 0 ? momentumBegin : momentumContinue)
                post(scroll)
                usleep(momentumFrameUs)
            }
            // Close the tail or the next gesture's phaseBegan is ignored.
            if !plan.momentum.isEmpty,
               let close = scrollEvent(ScrollFrame(vertical: 0, horizontal: 0), at: midpoint) {
                close.setIntegerValueField(fieldScrollPhase, value: 0)
                close.setIntegerValueField(fieldMomentumPhase, value: momentumEnd)
                post(close)
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
