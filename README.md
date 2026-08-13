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
   → screenshot / read_screen / tap / paste_text …  (drive the app on-device)
   → wait_for_text / tap with expect / sim_log      (assert what the user sees)
```

## Requirements

- macOS 15+ (built and tested on macOS 26) with the iPhone Mirroring app
  paired to an iPhone (nearby, locked, same Apple ID).
- Xcode + command line tools (for the `xcode_*`, `devices`, `device_*`,
  `sim_*` tools).
- TCC permissions granted to **the app that launches the server** (your
  terminal, or the Claude desktop app):
  - **Accessibility** — System Settings → Privacy & Security → Accessibility
    (send taps/keystrokes)
  - **Screen Recording** — System Settings → Privacy & Security → Screen &
    System Audio Recording (capture the window)
  - **Automation → System Events** — granted on first use (resume-overlay
    clicks, activation fallback, notification clicks)

  The `doctor` tool self-tests all of them end-to-end, including whether
  posted input events are actually being delivered.

## Build & install

```sh
swift build -c release
claude mcp add --scope user iphone-mirror -- "$PWD/.build/release/iphone-mirror-mcp"
```

(Or add the binary path to any MCP client's stdio server config.)

## Tools (63)

### Mirroring — session & health
| Tool | Purpose |
|---|---|
| `status` | Session state, window geometry, orientation, permission checks |
| `doctor` | **Full self-test**: 4 permissions, capture round-trip, input-delivery probe |
| `mirror_launch` | Launch/focus iPhone Mirroring and wait for the window |
| `mirror_restart` | Quit + relaunch + resume — the fix for a zombie session |

### Mirroring — screen
| Tool | Purpose |
|---|---|
| `screenshot` | PNG of the phone screen (optional `max_width` downscale) |
| `annotated_screenshot` | Screenshot with every OCR element boxed + numbered, with legend |
| `read_screen` | OCR every text element with tappable centers |
| `find_text` / `tap_text` | Locate / locate-and-tap text (`expect` verifies the tap) |
| `find_image` / `tap_image` | Template-match icons OCR can't name (crops from screenshots) |
| `wait_for_text` | Poll until text appears (loading screens, async UI) |
| `wait_for_screen_change` | Poll until the screen changes / goes stable (perceptual diff) |
| `scroll_to` | Swipe repeatedly until text becomes visible |
| `record_screen` | Fixed-duration recording to `.mov` |
| `record_start` / `record_stop` | **Detached** recording while input tools keep driving |
| `notifications` / `notification_click` | List / open banners (iPhone notifications land on the Mac while mirroring) |

### Mirroring — input
| Tool | Purpose |
|---|---|
| `tap` / `double_tap` / `long_press` | Pointer gestures at screenshot pixels (`tap` supports `expect`) |
| `swipe` | Trackpad-phase scroll gesture (momentum flicks included) |
| `drag` | Sustained press-drag (icons, sliders, drag & drop) |
| `type_text` | Keystroke typing (ASCII; skips & reports unmappable chars) |
| `paste_text` | **Full-fidelity text via the bridged clipboard** (emoji/CJK/long strings); restores the user's clipboard |
| `read_clipboard` | ⌘C on the phone → read the exact selected text (no OCR) |
| `press_key` | Single key / shortcut, e.g. `return`, `cmd+a` |
| `home` / `app_switcher` / `spotlight` | System navigation (View menu, ⌘1/⌘2/⌘3 fallback) |
| `launch_app` / `open_url` | Spotlight app launch; Safari URL navigation |
| `shake` | iOS shake gesture (⌃⌘Z) |
| `batch` | Up to 30 input steps in one call; stops at the first failure |

### Xcode & physical devices
| Tool | Purpose |
|---|---|
| `xcode_list` | Schemes/targets/configurations (`-list -json`) |
| `xcode_build` / `xcode_test` | Build/test with condensed summaries; tests keep an `.xcresult` |
| `xcresult_attachments` | Export failure screenshots/attachments from an `.xcresult` |
| `devices` | Paired physical devices (devicectl) + simulators (simctl) |
| `device_install` / `device_launch` | Install/launch on the iPhone (optional console capture) |
| `device_info` / `device_apps` / `device_uninstall` | Battery/OS/storage, installed apps, uninstall |
| `run_on_iphone` | **Build → install → launch on the paired iPhone in one call** |

### Simulators
| Tool | Purpose |
|---|---|
| `run_on_sim` | **Build → boot → install → launch on a simulator in one call** |
| `sim_boot` / `sim_install` / `sim_launch` / `sim_terminate` | Lifecycle |
| `sim_screenshot` / `sim_openurl` | Screen capture and deep links |
| `sim_log` | Recent unified log, filtered by process/predicate |
| `sim_push` | Deliver an APNs payload (test push flows) |
| `sim_privacy` | Grant/revoke/reset permissions (photos, location, …) |
| `sim_appearance` / `sim_statusbar` / `sim_location` | Dark mode, clean status bar, GPS |
| `sim_addmedia` / `sim_apps` / `sim_uninstall` / `sim_erase` | Photos library, app list, removal, factory reset |

## Coordinate contract

Every `x`/`y` is a **pixel position in the most recent screenshot** (origin
top-left). At input time the window bounds are re-queried and the pixel maps
proportionally into the current bounds, so a window that moved or resized
between screenshot and tap still receives the tap at the right spot.

## Architecture

```
Sources/
  MirrorCore/     platform layer — window bridge (AX + CGWindowList),
                  CGEvent input (delta-march cursor engagement, trackpad-
                  phase swipes, flagsChanged modifiers), ScreenCaptureKit
                  capture, Vision OCR, template matching, clipboard bridge,
                  notification bridge, xcodebuild/devicectl/simctl wrappers
  MirrorServer/   MCP layer — tool catalog, argument decoding, dispatch
  iphone-mirror-mcp/  stdio entry point
```

Mechanics worth knowing — the scroll/keyboard groundwork was reverse-
engineered by [mirroir-mcp](https://github.com/jfarcand/mirroir-mcp); the
pointer-engagement recipe below was established by live experimentation
against macOS 26:

- **The cursor is the input route.** iPhone Mirroring integrates the pointer
  from movement **deltas** like a physical mouse. A warped or zero-delta
  cursor leaves the app's internal pointer behind, and clicks then resolve at
  the stale internal position. Every pointer gesture therefore delta-marches
  the cursor (through the window-center engagement waypoint when entering),
  wiggles at the target, waits out the pointer-integration settle, and
  **verifies events were delivered** before posting the click.
- After an activation that changes focus, the window's unhide animation
  (hide-on-blur) discards **all** input for ~1.5s — the activation path waits
  it out, and re-asserts frontmost immediately before every post (the user
  can refocus their terminal with one keystroke mid-call).
- The mirroring window is missing from `AXWindows`; only `AXMainWindow`
  reaches it. Bounds come from `CGWindowList` — including an `.optionAll`
  pass that recovers the real window ID while the window is hidden, because
  the app also owns menu-bar-sized phantom windows that a naive lookup
  captures as a blank strip.
- Swipes are trackpad-style continuous scrolls: `MayBegin` priming, phase
  Began/Changed frames, a zero-delta lift, then a decaying momentum tail. The
  whole phase script is materialized before anything posts — a truncated
  sequence wedges SpringBoard and zombies the session (video streams, all
  input dropped; `mirror_restart` recovers).
- Session state is detected via AX children; pause overlays expose **no**
  AX buttons, so resume falls back to clicks at the two known overlay
  layouts (Resume at center, "iPhone in Use → Connect" at ~65% height).
- `NSWorkspace` snapshots and the system-wide AX focus query both fail in a
  run-loop-less stdio server; process lookups hit Launch Services fresh and
  frontmost comes from `CGWindowList` order.

## Known limitations (tested, not guessed)

- **Pinch/rotate cannot be synthesized.** Trackpad gestures do not travel
  the CGEvent pipeline (an event tap sees nothing during a physical pinch),
  so there is nothing a user process can post — every documented private
  encoding was tried against a live map and none delivered. `double_tap`
  zooms in where apps support it; modifier+scroll is not translated; ⌘+/⌘−
  are consumed by the Mac app for window sizing.
- **One phone at a time.** Device switching lives in the app's Settings
  dialog; there is no scriptable device menu.
- The session **pauses whenever the phone is unlocked or picked up** — that
  is Apple's design. Resume needs the phone locked again.
- No phone-side accessibility tree: OCR + template matching are the element
  model. Face ID, Control Center, and hardware buttons are unreachable; DRM
  content captures black.

## Testing

```sh
scripts/run_tests.sh                    # build + unit/protocol tests
MIRROR_MCP_LIVE=1 scripts/run_tests.sh  # + live tests (real window, capture, input delivery)
```

The protocol suite runs a real MCP client against the server over an
in-memory transport — list/call round-trips, error shapes, schema validity.
The live seam tests exist because several mechanisms (AX focus, event
delivery) behave differently in test runners than in the real server
process — they verify against the running window server.

## Security notes

This server can see and control whatever iPhone the Mac is paired with while
the mirroring session is active. Treat it like handing your unlocked phone to
the model: run it only from clients you trust, and remember the phone locks
the session whenever it is picked up or unlocked physically. `paste_text`
briefly places text on the Mac clipboard (and restores what was there);
`read_clipboard` reads it.
