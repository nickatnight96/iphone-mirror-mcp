<!-- GENERATED FILE — DO NOT EDIT BY HAND.
     Regenerate with: scripts/generate_tool_docs.py -->

# Tool reference

Every tool this server exposes, generated from the server's own catalog so it
always matches the shipped binary.

- **63 tools** in `iphone-mirror-mcp 1.0.1`
- Parameters marked **required** must be supplied; everything else is optional.

## Coordinate contract

Every `x` / `y` is a **pixel position in the most recent screenshot**, origin
top-left. At input time the window bounds are re-queried and the pixel is
mapped proportionally into the current bounds — so a window that moved or was
resized between the screenshot and the tap still receives the tap in the right
place.

The usual loop:

```
screenshot  →  find the element (read_screen / find_text / find_image)
            →  tap / swipe
            →  screenshot to verify
```


## Index

- **[Session & health](#session-health)** — [`status`](#status), [`doctor`](#doctor), [`mirror_launch`](#mirror_launch), [`mirror_restart`](#mirror_restart)
- **[Screen: capture & reading](#screen-capture-reading)** — [`screenshot`](#screenshot), [`annotated_screenshot`](#annotated_screenshot), [`read_screen`](#read_screen), [`find_text`](#find_text), [`find_image`](#find_image), [`wait_for_text`](#wait_for_text), [`wait_for_screen_change`](#wait_for_screen_change), [`scroll_to`](#scroll_to), [`record_screen`](#record_screen), [`record_start`](#record_start), [`record_stop`](#record_stop)
- **[Input: gestures & typing](#input-gestures-typing)** — [`tap`](#tap), [`tap_text`](#tap_text), [`tap_image`](#tap_image), [`double_tap`](#double_tap), [`long_press`](#long_press), [`swipe`](#swipe), [`drag`](#drag), [`type_text`](#type_text), [`paste_text`](#paste_text), [`read_clipboard`](#read_clipboard), [`press_key`](#press_key), [`shake`](#shake), [`batch`](#batch)
- **[Navigation](#navigation)** — [`home`](#home), [`app_switcher`](#app_switcher), [`spotlight`](#spotlight), [`launch_app`](#launch_app), [`open_url`](#open_url)
- **[Notifications](#notifications)** — [`notifications`](#notifications), [`notification_click`](#notification_click)
- **[Xcode: build & test](#xcode-build-test)** — [`xcode_list`](#xcode_list), [`xcode_build`](#xcode_build), [`xcode_test`](#xcode_test), [`xcresult_attachments`](#xcresult_attachments)
- **[Physical devices](#physical-devices)** — [`devices`](#devices), [`run_on_iphone`](#run_on_iphone), [`device_install`](#device_install), [`device_launch`](#device_launch), [`device_info`](#device_info), [`device_apps`](#device_apps), [`device_uninstall`](#device_uninstall)
- **[Simulators](#simulators)** — [`run_on_sim`](#run_on_sim), [`sim_boot`](#sim_boot), [`sim_install`](#sim_install), [`sim_launch`](#sim_launch), [`sim_terminate`](#sim_terminate), [`sim_screenshot`](#sim_screenshot), [`sim_openurl`](#sim_openurl), [`sim_log`](#sim_log), [`sim_push`](#sim_push), [`sim_privacy`](#sim_privacy), [`sim_appearance`](#sim_appearance), [`sim_statusbar`](#sim_statusbar), [`sim_location`](#sim_location), [`sim_addmedia`](#sim_addmedia), [`sim_apps`](#sim_apps), [`sim_uninstall`](#sim_uninstall), [`sim_erase`](#sim_erase)

## Session & health

Start here when anything misbehaves.

### `status`

Report the iPhone Mirroring session state (connected/paused/not running), window geometry, device orientation, and whether the Accessibility and Screen Recording permissions are granted. Call this first when anything misbehaves.

_No parameters._

### `doctor`

Non-destructive end-to-end self-test: all four permissions (Accessibility, Screen Recording, post-event access, Automation/System Events), session + window state, a capture round-trip, and an input-delivery probe (marches the cursor and verifies events actually moved it — no clicks posted). Run this first when input or capture misbehaves.

_No parameters._

### `mirror_launch`

Launch (or focus) the built-in iPhone Mirroring app and wait for its window. Use when status reports notRunning or noWindow.

_No parameters._

### `mirror_restart`

Fully restart the iPhone Mirroring app: quit, relaunch, resume. THE recovery for a zombie session — video updates but every tap/key is silently ignored. Also useful when the session is wedged in any other way.

_No parameters._


## Screen: capture & reading

Everything that answers *what is on the phone right now*.

### `screenshot`

Capture the mirrored iPhone screen as a PNG. Coordinates are pixel positions in the most recent screenshot (origin top-left). By default the image is returned at full capture resolution so what you see IS the coordinate space. Optional max_width downscales the returned image to save tokens — coordinates must then be scaled back to full resolution (the caption tells you the factor).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `max_width` | number | no | Optional: cap the returned image width in pixels (coordinates stay full-resolution) |

### `annotated_screenshot`

Screenshot with every OCR text element boxed and numbered, plus a legend of index → text/center. One call to see exactly where the tappable coordinates are. Coordinates are pixel positions in the most recent screenshot (origin top-left).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `max_width` | number | no | Optional: cap the returned image width in pixels (coordinates stay full-resolution) |

### `read_screen`

OCR the current iPhone screen and list every recognized text element with its center (directly tappable) and bounding box in screenshot pixel coordinates. Cheaper than a screenshot for text-heavy screens.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `fast` | boolean | no | Faster, less accurate recognition (default false) |

### `find_text`

Find on-screen text matching a query (exact match ranks first, then prefix, then substring; case-insensitive). Returns matches with tappable centers.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query` | string | **yes** | The on-screen text to look for |
| `exact` | boolean | no | Only exact (case-insensitive) matches |

### `find_image`

Find a template image on the iPhone screen via template matching — for icon-only UI that OCR cannot name. The template should be a CROP from a previous screenshot at full resolution (same pixel scale). Returns matches with tappable centers, best first. Coordinates are pixel positions in the most recent screenshot (origin top-left).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `min_score` | number | no | Match threshold 0.3-0.999 (default 0.8) |
| `multi_scale` | boolean | no | Also try 0.75×-1.35× template scales (default false; slower) |
| `template_base64` | string | no | Alternatively, the template image as base64 |
| `template_path` | string | no | Path to the template image file (PNG/JPEG) |

### `wait_for_text`

Poll the screen (OCR) until the given text appears — for loading screens, transitions, async UI. Fails after the timeout.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | **yes** | The text to wait for on screen |
| `exact` | boolean | no | Require an exact, full-string match instead of a case-insensitive substring match (default false) |
| `timeout_seconds` | number | no | Default 15, max 120 |

### `wait_for_screen_change`

Poll until the screen visually CHANGES (mode "changed") or STOPS changing (mode "stable", e.g. an animation finished) using a perceptual frame diff — complements wait_for_text for imagery OCR cannot read. Returns the elapsed time.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `mode` | string | no | "changed" (default) or "stable" |
| `threshold` | number | no | Normalized difference 0-1 that counts as a change (default 0.02) |
| `timeout_seconds` | number | no | Default 15, max 120 |

### `scroll_to`

Swipe repeatedly (direction = finger direction; "up" scrolls down the page) until the given text becomes visible, then report its tappable center.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | **yes** | The text to scroll until it becomes visible |
| `direction` | string | no | up (default), down, left, right |
| `max_swipes` | number | no | Default 8, max 20 |

### `record_screen`

Record the mirrored iPhone screen to a .mov file for a fixed duration and return the file path. The window must stay visible while recording.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `seconds` | number | **yes** | Duration, 1-600 |
| `output_path` | string | no | Optional .mov output path |

### `record_start`

Start a DETACHED screen recording of the mirrored iPhone — tap/swipe/type tools keep working while it runs. Stop with record_stop to get the .mov. The mirroring window must stay visible on screen for the whole recording (input tools keep it frontmost automatically).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `output_path` | string | no | Optional .mov output path |

### `record_stop`

Stop the detached recording started by record_start and return the finalized .mov path.

_No parameters._


## Input: gestures & typing

Every `x`/`y` is a pixel in the most recent screenshot. See [the coordinate contract](#coordinate-contract).

### `tap`

Tap the iPhone screen. Coordinates are pixel positions in the most recent screenshot (origin top-left). Pass expect to VERIFY the tap: the call fails unless that text appears afterwards — strongly recommended, silent misses are this transport's main failure mode.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `x` | number | **yes** | X pixel coordinate in the last screenshot |
| `y` | number | **yes** | Y pixel coordinate in the last screenshot |
| `expect` | string | no | Text that must appear on screen after the tap (verified via OCR polling) |
| `expect_timeout_seconds` | number | no | How long to wait for expect (default 10) |

### `tap_text`

OCR-locate text on screen and tap its center. Best-match first; pass index to pick a later match. Pass expect to VERIFY the tap: the call fails unless that text appears afterwards — strongly recommended.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query` | string | **yes** | The on-screen text to find and tap |
| `exact` | boolean | no | Require an exact, full-string match instead of a case-insensitive substring match (default false) |
| `expect` | string | no | Text that must appear on screen after the tap (verified via OCR polling) |
| `expect_timeout_seconds` | number | no | How long to wait for expect (default 10) |
| `index` | number | no | Which match to tap (0-based, default 0) |

### `tap_image`

Find a template image on the screen (see find_image) and tap the best match's center. Pass expect to verify the tap took effect.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `expect` | string | no | Text that must appear after the tap |
| `expect_timeout_seconds` | number | no | Default 10 |
| `min_score` | number | no | Match threshold 0.3-0.999 (default 0.8) |
| `multi_scale` | boolean | no | Also try 0.75×-1.35× template scales (default false) |
| `template_base64` | string | no | Alternatively, the template image as base64 |
| `template_path` | string | no | Path to the template image file (PNG/JPEG) |

### `double_tap`

Double-tap the iPhone screen (zoom, text selection). Coordinates are pixel positions in the most recent screenshot (origin top-left).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `x` | number | **yes** | X pixel coordinate in the last screenshot |
| `y` | number | **yes** | Y pixel coordinate in the last screenshot |

### `long_press`

Long-press the iPhone screen (context menus, app-icon menus). Coordinates are pixel positions in the most recent screenshot (origin top-left).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `x` | number | **yes** | X pixel coordinate in the last screenshot |
| `y` | number | **yes** | Y pixel coordinate in the last screenshot |
| `duration_ms` | number | no | Hold duration, default 600 |

### `swipe`

Swipe/scroll with a trackpad-style gesture — content follows the finger (swipe up = scroll down the page). Fast swipes flick with momentum. Use drag instead for moving icons or sliders. Coordinates are pixel positions in the most recent screenshot (origin top-left).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `from_x` | number | **yes** | X pixel coordinate the gesture starts at, in the last screenshot |
| `from_y` | number | **yes** | Y pixel coordinate the gesture starts at, in the last screenshot |
| `to_x` | number | **yes** | X pixel coordinate the gesture ends at |
| `to_y` | number | **yes** | Y pixel coordinate the gesture ends at |
| `duration_ms` | number | no | Gesture duration in ms. Shorter is faster: a swipe under ~300ms flicks with momentum, longer drags the content directly |

### `drag`

Sustained press-and-drag (rearrange icons, sliders, drag-and-drop) — distinct from swipe, which scrolls. Coordinates are pixel positions in the most recent screenshot (origin top-left).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `from_x` | number | **yes** | X pixel coordinate the gesture starts at, in the last screenshot |
| `from_y` | number | **yes** | Y pixel coordinate the gesture starts at, in the last screenshot |
| `to_x` | number | **yes** | X pixel coordinate the gesture ends at |
| `to_y` | number | **yes** | Y pixel coordinate the gesture ends at |
| `duration_ms` | number | no | Gesture duration in ms. Shorter is faster: a swipe under ~300ms flicks with momentum, longer drags the content directly |

### `type_text`

Type text on the mirrored iPhone via keystrokes (a text field must be focused — tap it first). ASCII only; characters like emoji/CJK/accents are skipped and reported. Set submit=true to press Return afterwards.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | **yes** | The text to type |
| `submit` | boolean | no | Press Return after typing (default false) |

### `paste_text`

Paste text into the focused phone text field via the bridged clipboard (⌘V) — full fidelity (emoji/CJK/accents survive) and instant for long strings, unlike type_text's ASCII keystrokes. The user's Mac clipboard is saved and restored. A text field must be focused (tap it first). Set submit=true to press Return afterwards.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | **yes** | The text to type |
| `submit` | boolean | no | Press Return after pasting (default false) |

### `read_clipboard`

Read the clipboard as text. With copy_first=true (default), presses ⌘C on the phone first, copying the current selection through the bridged clipboard — the way to extract exact text from the phone without OCR. Select the text on the phone first (long_press + drag handles, or tap a text field and cmd+a via press_key).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `copy_first` | boolean | no | Press ⌘C on the phone before reading (default true) |

### `press_key`

Press a single key or shortcut on the mirrored iPhone, e.g. "return", "escape", "delete", "up"/"down"/"left"/"right", "cmd+a", "cmd+l". Note: most app-level Mac shortcuts do not pass through mirroring; navigation keys and text-editing shortcuts do.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `key` | string | **yes** | Key spec like "return" or "cmd+a" |

### `shake`

Trigger the iOS shake gesture (⌃⌘Z) — undo dialogs, developer menus (e.g. React Native).

_No parameters._

### `batch`

Run several input steps in ONE call — far faster than separate tool calls for scripted flows. Steps run in order; the first failure stops the batch and reports the step index. Step tools: tap, double_tap, long_press, swipe, drag, type_text, paste_text, press_key, tap_text, wait_for_text, home, app_switcher, spotlight, launch_app, open_url, sleep_ms. Each step: {"tool": name, "args": {…}} with the same args as the standalone tool.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `steps` | array | **yes** | Input steps to run in order, e.g. [{"tool": "tap_text", "args": {"query": "Settings"}}, {"tool": "sleep_ms", "args": {"ms": 500}}]. Max 30 |


## Navigation

System-level movement around iOS.

### `home`

Go to the iPhone Home Screen (View menu / ⌘1).

_No parameters._

### `app_switcher`

Open the iPhone App Switcher (View menu / ⌘2). From here you can swipe an app card up (drag upward) to force-quit it.

_No parameters._

### `spotlight`

Open iPhone Spotlight search (View menu / ⌘3).

_No parameters._

### `launch_app`

Launch an iPhone app by name: opens Spotlight, types the name, presses Return to launch the top hit. Verify with a screenshot — Spotlight's top hit can differ from the intent.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | **yes** | App name as it appears on the phone |

### `open_url`

Open a URL on the iPhone: launches Safari via Spotlight, focuses the address bar (⌘L), types the URL, presses Return.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `url` | string | **yes** | URL to open in Safari on the iPhone, including https:// |


## Notifications

iPhone notifications surface on the Mac while mirroring is active.

### `notifications`

List the notification banners on the Mac's screen. While mirroring is active, the iPhone's notifications are delivered HERE — this is how a flow observes "the push/message arrived". Banners exist only while visibly on screen (~5s), so pass wait_seconds to poll until one appears — trigger the notification, then call this with a wait.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `wait_seconds` | number | no | Poll up to this long for a banner to appear (default 0 = single check, max 60) |

### `notification_click`

Click a notification banner by index (from the notifications tool). Clicking a mirrored iPhone notification opens its app in the mirroring window.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `index` | number | no | Banner index (default 0 = topmost) |


## Xcode: build & test

Build and test any Xcode project or Swift package.

### `xcode_list`

List the schemes, targets, and build configurations of an Xcode project/workspace (xcodebuild -list -json).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `project_path` | string | no | Path to .xcodeproj/.xcworkspace or the project directory (default: current directory) |

### `xcode_build`

Build an Xcode scheme and return a condensed summary (outcome, errors, warnings). Long logs are parsed down to what matters.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `scheme` | string | **yes** | Xcode scheme to build. Run xcode_list to see the available schemes |
| `configuration` | string | no | Debug (default) or Release |
| `destination` | string | no | xcodebuild -destination string, e.g. "platform=iOS Simulator,name=iPhone 17 Pro" or "platform=iOS,id=<udid>" |
| `extra_args` | array | no | Additional xcodebuild arguments |
| `project_path` | string | no | Path to a .xcodeproj, .xcworkspace, or a package/project directory. Omit to use the current directory. |
| `timeout_seconds` | number | no | Default 900, max 3600 |

### `xcode_test`

Run an Xcode scheme's tests and return a condensed summary with test counts and failures. Defaults to the booted simulator when no destination is given. only_testing narrows to specific tests (Target/Class/testMethod).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `scheme` | string | **yes** | Xcode scheme to build. Run xcode_list to see the available schemes |
| `configuration` | string | no | Debug (default) or Release |
| `destination` | string | no | xcodebuild -destination string, e.g. "platform=iOS Simulator,name=iPhone 17 Pro" or "platform=iOS,id=<udid>" |
| `extra_args` | array | no | Additional xcodebuild arguments |
| `only_testing` | array | no | Limit to these test identifiers |
| `project_path` | string | no | Path to a .xcodeproj, .xcworkspace, or a package/project directory. Omit to use the current directory. |
| `timeout_seconds` | number | no | Default 900, max 3600 |

### `xcresult_attachments`

Export every attachment (failure screenshots, activity attachments, …) from an .xcresult bundle to a directory and list the files. xcode_test's output includes the bundle path.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `xcresult_path` | string | **yes** | Path to the .xcresult bundle |
| `output_dir` | string | no | Where to export (default: a temp directory) |


## Physical devices

Drive a real, paired iPhone through `devicectl`.

### `devices`

List paired physical iOS devices (devicectl) and available simulators (simctl), with names, udids, OS versions, and states.

_No parameters._

### `run_on_iphone`

THE end-to-end pipeline: build the scheme for the paired iPhone, install it via devicectl, and launch it. The app then appears on the mirrored screen, where the tap/swipe/OCR/screenshot tools can drive it — real-device automated testing without XCUITest.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `scheme` | string | **yes** | Xcode scheme to build. Run xcode_list to see the available schemes |
| `configuration` | string | no | Default Debug |
| `device` | string | no | Device name or udid (default: first paired iPhone) |
| `project_path` | string | no | Path to .xcodeproj/.xcworkspace or project directory (default: current directory) |
| `timeout_seconds` | number | no | Build timeout, default 900 |

### `device_install`

Install a built .app bundle on a paired physical device via devicectl.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app_path` | string | **yes** | Path to the .app bundle (device build, not simulator) |
| `device` | string | no | Device name or udid (default: first paired iPhone) |

### `device_launch`

Launch an app by bundle id on a paired physical device. Optional console_seconds attaches the console and captures the app's output for that long (the app keeps running afterwards). After launching, drive the app with the mirroring tools.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bundle_id` | string | **yes** | App bundle identifier, e.g. com.example.MyApp |
| `console_seconds` | number | no | Capture stdout/stderr for N seconds (default 0 = don't attach; capped at 300) |
| `device` | string | no | Device name or udid (default: first paired iPhone) |
| `terminate_existing` | boolean | no | Kill a running instance first (default true) |

### `device_info`

Detailed info for a paired physical device: OS build, battery, storage, model, lock state.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `device` | string | no | Device name or udid (default: first paired iPhone) |

### `device_apps`

List the apps installed on a paired physical device with bundle ids.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `device` | string | no | Device name or udid (default: first paired iPhone) |

### `device_uninstall`

Uninstall an app from a paired physical device by bundle id.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bundle_id` | string | **yes** | App bundle identifier, e.g. com.example.MyApp |
| `device` | string | no | Device name or udid (default: first paired iPhone) |


## Simulators

The full `simctl` surface.

### `run_on_sim`

Build the scheme for a simulator, boot it if needed, install, and launch — the simulator twin of run_on_iphone. Then drive it with sim_screenshot / sim_openurl (simulator coordinates are separate from the mirroring tools).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `scheme` | string | **yes** | Xcode scheme to build. Run xcode_list to see the available schemes |
| `configuration` | string | no | Default Debug |
| `project_path` | string | no | Path to .xcodeproj/.xcworkspace or project directory (default: current directory) |
| `simulator` | string | no | Simulator name or udid (default: the booted one, else the first available iPhone) |
| `timeout_seconds` | number | no | Build timeout, default 900 |

### `sim_boot`

Boot a simulator (and open the Simulator app so it is visible).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `simulator` | string | **yes** | Simulator name or udid |

### `sim_install`

Install a simulator-built .app on a simulator (default: the booted one).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app_path` | string | **yes** | Path to the built .app bundle |
| `simulator` | string | no | Name or udid (default: booted) |

### `sim_launch`

Launch an app by bundle id on a simulator (default: the booted one). Optional console_seconds captures the app's output.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bundle_id` | string | **yes** | App bundle identifier, e.g. com.example.MyApp |
| `console_seconds` | number | no | Capture output for N seconds (default 0; capped at 300) |
| `simulator` | string | no | Name or udid (default: booted) |

### `sim_terminate`

Terminate a running app on a simulator (default: the booted one).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bundle_id` | string | **yes** | App bundle identifier, e.g. com.example.MyApp |
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_screenshot`

Screenshot a simulator's screen (default: the booted one). Note: simulator coordinates are separate from the iPhone-mirroring coordinate space.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_openurl`

Open a URL (including deep links / universal links) on a simulator (default: the booted one).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `url` | string | **yes** | URL to open, including scheme (https://… or a custom deep link) |
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_log`

Read a simulator's recent unified log (default: the booted one) — the app's os_log/print output. Filter by process name (recommended: the app's name) and/or a custom NSPredicate.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `last` | string | no | How far back, e.g. "2m", "30s", "1h" (default 2m) |
| `predicate` | string | no | Additional NSPredicate, e.g. eventMessage contains "error" |
| `process` | string | no | Only entries from this process name |
| `simulator` | string | no | Name or udid (default: booted) |

### `sim_push`

Deliver a push notification to an app on a simulator (default: the booted one). payload is the APNs JSON — it must contain an "aps" key, e.g. {"aps":{"alert":{"title":"Hi","body":"There"},"badge":1}}.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bundle_id` | string | **yes** | App bundle identifier, e.g. com.example.MyApp |
| `payload` | string | **yes** | APNs payload JSON (must contain an aps key) |
| `simulator` | string | no | Name or udid (default: booted) |

### `sim_privacy`

Grant, revoke, or reset a privacy permission for an app on a simulator — test permission flows without tapping dialogs. Services: all, calendar, contacts, contacts-limited, location, location-always, photos, photos-add, media-library, microphone, motion, reminders, siri.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `action` | string | **yes** | grant, revoke, or reset |
| `service` | string | **yes** | Privacy service to change, e.g. photos, camera, microphone, location, contacts, or all |
| `bundle_id` | string | no | Required for grant/revoke; optional for reset |
| `simulator` | string | no | Name or udid (default: booted) |

### `sim_appearance`

Switch a simulator between light and dark appearance.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `appearance` | string | **yes** | light or dark |
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_statusbar`

Override a simulator's status bar (clean screenshots: 9:41, full battery/signal) or clear the overrides.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `battery_level` | number | no | 0-100 |
| `battery_state` | string | no | charged, charging, or discharging |
| `cellular_bars` | number | no | 0-4 |
| `clear` | boolean | no | Remove all overrides |
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |
| `time` | string | no | e.g. 9:41 |
| `wifi_bars` | number | no | 0-3 |

### `sim_location`

Set (or clear) a simulator's simulated GPS location.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `clear` | boolean | no | Clear the simulated location instead |
| `latitude` | number | no | Latitude in decimal degrees |
| `longitude` | number | no | Longitude in decimal degrees |
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_addmedia`

Add photos/videos (file paths) to a simulator's Photos library.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `paths` | array | **yes** | Image/video file paths |
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_apps`

List the apps installed on a simulator (default: the booted one) with bundle ids.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_uninstall`

Uninstall an app from a simulator (default: the booted one).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bundle_id` | string | **yes** | App bundle identifier, e.g. com.example.MyApp |
| `simulator` | string | no | Simulator UDID or name (e.g. "iPhone 16 Pro"). Defaults to the booted simulator |

### `sim_erase`

DESTRUCTIVE: factory-reset a simulator — erases all its apps, data, and settings. The simulator is shut down first if booted. Requires the simulator to be named explicitly.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `simulator` | string | **yes** | Name or udid — required, to prevent erasing the wrong one |
