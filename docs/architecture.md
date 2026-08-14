# Architecture

```
Sources/
  MirrorCore/          platform layer — window bridge (AX + CGWindowList),
                       CGEvent input, ScreenCaptureKit capture, Vision OCR,
                       template matching, clipboard and notification bridges,
                       xcodebuild / devicectl / simctl wrappers
  MirrorServer/        MCP layer — tool catalog, argument decoding, dispatch
  iphone-mirror-mcp/   stdio entry point and CLI
```

`MirrorCore` knows nothing about MCP; `MirrorServer` knows nothing about
CGEvent. That split is what lets the planners and parsers be unit-tested
without a phone attached — 150-odd tests run with no hardware.

## Concurrency

`MirrorSession` is an actor. Mirroring tools are additionally serialized
through a `ToolSerializer` so they run strictly FIFO: interleaved gestures and
captures corrupt each other, since they share one cursor and one window.
Xcode and simulator tools stay concurrent — they are separate processes with
no shared state.

## How input actually reaches the phone

This is the part that took the longest to get right, and none of it is
documented by Apple. Everything here was established by experimentation
against a live macOS 26 session.

**The cursor is the input route.** iPhone Mirroring integrates the pointer
from movement *deltas*, like a physical mouse — not from absolute position. A
warped or zero-delta cursor leaves the app's internal pointer behind, and
clicks then resolve wherever that stale internal position is. So every pointer
gesture:

1. delta-marches the cursor to the target, entering through the window-center
   engagement waypoint,
2. wiggles at the destination,
3. waits out the pointer-integration settle,
4. **verifies the events were actually delivered**, and only then posts the
   click.

**Activation discards input.** After an activation that changes focus, the
window's unhide animation (hide-on-blur) throws away *all* input for roughly
1.5 seconds. The activation path waits it out, and re-asserts frontmost
immediately before every post — the user can steal focus back to their
terminal with one keystroke mid-call.

**Everything posts at `.cghidEventTap`.** iPhone Mirroring ignores events
posted to its PID; it wants HID-level posting with the app frontmost.

## Finding the window

The mirroring window is missing from `AXWindows` — only `AXMainWindow` reaches
it. Bounds come from `CGWindowList`, including an `.optionAll` pass that
recovers the real window ID while the window is hidden, because the app also
owns menu-bar-sized phantom windows that a naive lookup happily captures as a
blank strip.

`NSWorkspace`'s running-applications snapshot freezes in a stdio server that
never pumps a run loop, and the system-wide AX focus query fails there too. So
process lookups hit Launch Services fresh every time, and "frontmost" is
derived from `CGWindowList` ordering.

## Gestures

A swipe is a trackpad-style continuous scroll, not a wheel event — bare scroll
events are ignored by the session. The full phase sequence is:

```
MayBegin prime → Began → Changed… → zero-delta Ended (the lift)
               → momentum Begin → Continue… → zero-delta momentum End
```

The deltas come from `SwipePlan`, which models the gesture as a **moving
finger sampled at the frame rate**: a position curve is evaluated at each
frame boundary and the emitted deltas are the differences between successive
samples. Displacement conservation is therefore structural — differences of a
rounded position curve telescope to exactly its endpoint — rather than
something a reconciliation pass has to restore.

Two regimes fall out of whether the finger is still moving at the lift:

- **Drag** (slow) — steady speed, stopped by the lift, no inertia. Linear
  position.
- **Flick** (fast) — accelerating, still moving at the lift, so iOS coasts the
  content under exponential deceleration. Quadratic during contact, then the
  decay integral.

For a flick the contact/inertia split is not a tuned ratio: integrating the
velocity profile gives contact `T/2` and inertia `τ` (the decay time
constant), so contact takes `T/2 / (T/2 + τ)` of the distance. The tail ends
where a frame stops carrying a whole wheel unit — past that the decay is still
mathematically alive but quantizes to a stuttering dribble.

**The whole phase script is materialized before anything posts.** This is a
hard invariant, not a style choice: a truncated sequence leaves iOS tracking a
finger that never lifted, SpringBoard wedges mid-transition, and every
subsequent input is dropped while video keeps streaming. `mirror_restart`
recovers; nothing else does. `SwipeScriptTests` pins the termination
guarantees across a broad input grid.

## Session state

State is detected through AX children. Pause overlays expose **no** AX
buttons, so resume falls back to clicking the two known overlay layouts —
Resume at the window center, and "iPhone in Use → Connect" at about 65% height.

## Reading the screen

There is no accessibility tree from the phone. The element model is:

- **Vision OCR** (`read_screen`, `find_text`) — text with tappable centers
- **Template matching** (`find_image`) — for icon-only UI that OCR cannot name
- **Perceptual diffing** (`wait_for_screen_change`) — mean absolute difference
  between downsampled frames, for animations and loading states

## Testing

```sh
scripts/run_tests.sh                    # build, unit + protocol tests, CLI smoke
MIRROR_MCP_LIVE=1 scripts/run_tests.sh  # + live tests against a real session
```

The protocol suite runs a real MCP client against the server over an in-memory
transport — list/call round-trips, error shapes, schema validity.

The live suite exists because several mechanisms behave differently in a test
runner than in the real server process: AX focus, event delivery, and the
run-loop-dependent APIs above. Those seams are only meaningfully verified
against a running window server, so they are gated behind `MIRROR_MCP_LIVE=1`
and skipped everywhere else, including CI. Run them hands-off: they share the
real cursor and window focus with whoever is at the keyboard.

The tool reference is generated from the server's own catalog
(`scripts/generate_tool_docs.py`), and CI fails if it is out of date — a tool
cannot ship undocumented.
