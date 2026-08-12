# iphone-mirror-mcp

An MCP server that drives a **real iPhone** through the built-in macOS
**iPhone Mirroring** app (`com.apple.ScreenContinuity`) and automates **Xcode
development testing** — build, test, install, and launch on simulators and
physical devices, then operate the app on the mirrored screen with taps,
swipes, typing, and OCR. No jailbreak, no software on the phone, no XCUITest
target required.

The flagship flow:

```
run_on_iphone (build → devicectl install → launch on the paired iPhone)
   → screenshot / read_screen / tap / type_text …  (drive the app on-device)
   → wait_for_text / find_text                     (assert what the user sees)
```

## Requirements

- macOS 15+ (built and tested on macOS 26) with the iPhone Mirroring app
  paired to an iPhone (nearby, locked, same Apple ID).
- Xcode + command line tools (for the `xcode_*`, `devices`, `device_*`,
  `sim_*` tools).
- Two TCC permissions granted to **the app that launches the server** (your
  terminal, or the Claude desktop app):
  - **Accessibility** — System Settings → Privacy & Security → Accessibility
    (needed to send taps/keystrokes)
  - **Screen Recording** — System Settings → Privacy & Security → Screen &
    System Audio Recording (needed to capture the window)

  The `status` tool reports both, live.

## Build & install

```sh
swift build -c release
claude mcp add --scope user iphone-mirror -- "$PWD/.build/release/iphone-mirror-mcp"
```

(Or add the binary path to any MCP client's stdio server config.)

## Tools (35)

### Mirroring — session
| Tool | Purpose |
|---|---|
| `status` | Session state, window geometry, orientation, permission checks |
| `mirror_launch` | Launch/focus iPhone Mirroring and wait for the window |

### Mirroring — screen
| Tool | Purpose |
|---|---|
| `screenshot` | PNG of the phone screen (optional `max_width` downscale) |
| `read_screen` | OCR every text element with tappable centers |
| `find_text` / `tap_text` | Locate / locate-and-tap text on screen |
| `wait_for_text` | Poll until text appears (loading screens, async UI) |
| `scroll_to` | Swipe repeatedly until text becomes visible |
| `record_screen` | Record the window to a `.mov` for N seconds |

### Mirroring — input
| Tool | Purpose |
|---|---|
| `tap` / `double_tap` / `long_press` | Pointer gestures at screenshot pixels |
| `swipe` | Trackpad-phase scroll gesture (momentum flicks included) |
| `drag` | Sustained press-drag (icons, sliders, drag & drop) |
| `type_text` | Keystroke typing (ASCII; skips & reports unmappable chars) |
| `press_key` | Single key / shortcut, e.g. `return`, `cmd+a` |
| `home` / `app_switcher` / `spotlight` | System navigation (View menu, ⌘1/⌘2/⌘3 fallback) |
| `launch_app` / `open_url` | Spotlight app launch; Safari URL navigation |
| `shake` | iOS shake gesture (⌃⌘Z) |

### Xcode & devices
| Tool | Purpose |
|---|---|
| `xcode_list` | Schemes/targets/configurations (`-list -json`) |
| `xcode_build` / `xcode_test` | Build/test with condensed error+test summaries |
| `devices` | Paired physical devices (devicectl) + simulators (simctl) |
| `device_install` / `device_launch` | Install/launch on the physical iPhone (optional console capture) |
| `run_on_iphone` | **Build → install → launch on the paired iPhone in one call** |
| `sim_boot` / `sim_install` / `sim_launch` / `sim_terminate` | Simulator lifecycle |
| `sim_screenshot` / `sim_openurl` | Simulator screen capture and deep links |

## Coordinate contract

Every `x`/`y` is a **pixel position in the most recent screenshot** (origin
top-left). At input time the window bounds are re-queried and the pixel maps
proportionally into the current bounds, so a window that moved or resized
between screenshot and tap still receives the tap at the right spot.

## Architecture

```
Sources/
  MirrorCore/     platform layer — window bridge (AX + CGWindowList),
                  CGEvent input (trackpad-phase swipes, flagsChanged
                  modifiers), ScreenCaptureKit capture, Vision OCR,
                  xcodebuild/devicectl/simctl wrappers, pure parsers
  MirrorServer/   MCP layer — tool catalog, argument decoding, dispatch
  iphone-mirror-mcp/  stdio entry point
```

Mechanics worth knowing (mostly reverse-engineered by the
[mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) project, whose
findings this implementation gratefully builds on):

- The mirroring window is missing from `AXWindows`; only `AXMainWindow`
  reaches it. Window bounds come from `CGWindowList` (AX lags).
- Events must post at the HID tap with the app frontmost; posting to the PID
  is ignored. Re-activating an already-active app drops the next click.
- Swipes are trackpad-style continuous scrolls: `MayBegin` priming, phase
  Began/Changed frames, a zero-delta lift, then a decaying momentum tail for
  flicks. Bare scroll-wheel events are ignored.
- Modifier keys need explicit `flagsChanged` events around the keystroke.
- Session state is detected via AX children: an opaque video surface (no
  children) means connected; overlay children mean paused, and the server
  auto-clicks Resume/OK before every input.
- `NSWorkspace`'s app snapshot freezes in a stdio server; every process
  lookup queries Launch Services fresh.

## Testing

```sh
scripts/run_tests.sh                    # build + 78 unit/protocol tests
MIRROR_MCP_LIVE=1 scripts/run_tests.sh  # + live tests (real window, capture, CLIs)
```

The protocol suite runs a real MCP client against the server over an
in-memory transport — list/call round-trips, error shapes, schema validity.

## Security notes

This server can see and control whatever iPhone the Mac is paired with while
the mirroring session is active. Treat it like handing your unlocked phone to
the model: run it only from clients you trust, and remember the phone locks
the session whenever it is picked up or unlocked physically.
