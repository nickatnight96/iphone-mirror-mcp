# Recipes

Worked patterns for driving a real iPhone. Prompts are written the way you
would actually type them; the tool sequences show what the model does.

- [The core loop](#the-core-loop)
- [Driving an app you did not write](#driving-an-app-you-did-not-write)
- [The on-device test loop](#the-on-device-test-loop)
- [Reacting to a notification](#reacting-to-a-notification)
- [Entering text reliably](#entering-text-reliably)
- [Finding things OCR cannot name](#finding-things-ocr-cannot-name)
- [Recording a flow](#recording-a-flow)
- [Simulators instead of a phone](#simulators-instead-of-a-phone)
- [Making flows fast](#making-flows-fast)

---

## The core loop

Almost everything is:

```
screenshot / read_screen     what is on screen?
        ↓
find_text / find_image       where is the thing?
        ↓
tap / swipe / type_text      act
        ↓
wait_for_text / screenshot   confirm it worked
```

The confirmation step matters more than it looks. Prefer the tools that verify
their own effect:

- `tap` takes an `expect` string and checks that text appears afterwards
- `tap_text` finds and taps in one call, with the same `expect`
- `wait_for_text` polls instead of guessing at a `sleep`
- `wait_for_screen_change` handles animations and loading with no known text

> Open Settings, tap General, and confirm you landed on the General page.

```
launch_app  {"name": "Settings"}
tap_text    {"query": "General", "expect": "About"}
```

## Driving an app you did not write

No source, no accessibility tree — OCR and template matching are the whole
element model.

> Open Instagram, find the first post, and tell me who posted it.

```
launch_app          {"name": "Instagram"}
wait_for_screen_change {"mode": "stable", "timeout_seconds": 10}
annotated_screenshot                  ← every OCR element boxed and numbered
tap                 {"x": 120, "y": 340}
```

`annotated_screenshot` is the one to reach for when a screen is unfamiliar: it
returns the image with every recognized element outlined, numbered, and
legended, so the model can pick a target by sight instead of guessing pixels.

When a list is long:

```
scroll_to  {"text": "Settings and privacy", "direction": "down", "max_swipes": 10}
```

## The on-device test loop

The flagship flow — build, install, launch, and drive your own app on real
hardware, with no XCUITest target.

> Build and run MyApp on my iPhone, sign in as the test user, and screenshot the home screen.

```
run_on_iphone  {"scheme": "MyApp"}          ← build → install → launch
wait_for_text  {"text": "Sign in", "timeout_seconds": 30}
tap_text       {"query": "Email"}
paste_text     {"text": "test@example.com"}
tap_text       {"query": "Password"}
paste_text     {"text": "…", "submit": true}
wait_for_text  {"text": "Home", "timeout_seconds": 20}
screenshot
```

Iterating on a fix:

```
xcode_build    {"scheme": "MyApp"}     ← fast feedback, no install
run_on_iphone  {"scheme": "MyApp"}     ← when you want it on the phone
xcode_test     {"scheme": "MyApp"}     ← unit/UI tests, keeps an .xcresult
xcresult_attachments {"xcresult_path": "…"}   ← failure screenshots
```

`xcode_build` and `xcode_test` return condensed summaries rather than
thousands of lines of `xcodebuild` output, so a failure does not flood the
context window.

## Reacting to a notification

iPhone notifications appear on the Mac while mirroring, and this server can
read and open them.

> Watch for a verification code and tell me what it says.

```
notifications      {"wait_seconds": 60}
notification_click {"index": 0}      ← opens the owning app
read_screen
```

Useful for two-factor codes, delivery updates, or waiting on a message during
a test.

## Entering text reliably

| Situation | Use |
|---|---|
| Plain ASCII into a focused field | `type_text` |
| Emoji, CJK, accents, anything long | `paste_text` |
| Reading text back exactly | `read_clipboard` |
| Return, ⌘A, and friends | `press_key` |

`type_text` posts real keystrokes and silently cannot express non-ASCII — it
reports what it skipped. `paste_text` routes through the bridged clipboard at
full fidelity and puts your previous clipboard back afterwards.

Always focus the field first (`tap` or `tap_text`); keystrokes go nowhere
otherwise.

To read exact text rather than OCR's best guess — select it, then:

```
read_clipboard  {"press_copy": true}
```

Some fields (Spotlight, notably) do not bridge the copy back. OCR remains the
fallback.

## Finding things OCR cannot name

Icon-only buttons have no text. Crop the icon from a full-resolution
screenshot and match it:

```
screenshot                      ← save it, crop the icon out
find_image  {"template_path": "/tmp/heart.png", "min_score": 0.8}
tap_image   {"template_path": "/tmp/heart.png"}
```

The crop must come from a screenshot at the **same pixel scale** — a crop from
a `max_width`-downscaled image will not match. If it fails, lower `min_score`
or set `multi_scale: true` (slower, tries 0.75×–1.35×).

## Recording a flow

Fixed duration:

```
record_screen  {"seconds": 10, "output_path": "/tmp/flow.mov"}
```

Or record *while* driving, which is usually what you want for a bug report:

```
record_start  {"output_path": "/tmp/repro.mov"}
tap_text      {"query": "Checkout"}
…
record_stop
```

`record_start` is detached, so input tools keep working while it captures.

## Simulators instead of a phone

Everything above needs a physical iPhone. For flows that do not, simulators
are faster and scriptable in ways a real phone is not:

```
run_on_sim     {"scheme": "MyApp", "simulator": "iPhone 16 Pro"}
sim_privacy    {"action": "grant", "service": "photos"}
sim_location   {"latitude": 37.33, "longitude": -122.03}
sim_push       {"bundle_id": "com.example.MyApp", "payload_path": "/tmp/push.json"}
sim_statusbar  {"time": "9:41"}          ← clean screenshots
sim_appearance {"appearance": "dark"}
sim_log        {"process": "MyApp"}
```

Push notifications, GPS, permission grants, and a pinned status bar have no
equivalent on a real device through mirroring.

## Making flows fast

Each tool call is a round trip. For a known sequence, `batch` runs up to 30
input steps in one call and stops at the first failure, reporting the index:

```json
{
  "steps": [
    {"tool": "launch_app", "args": {"name": "Settings"}},
    {"tool": "wait_for_text", "args": {"text": "General"}},
    {"tool": "tap_text", "args": {"query": "General"}},
    {"tool": "sleep_ms", "args": {"ms": 400}},
    {"tool": "tap_text", "args": {"query": "About"}}
  ]
}
```

Use it for the parts of a flow you already trust. Keep exploration as
individual calls, where the model can look before each step.

Other cheap wins: `read_screen` instead of a screenshot when you only need
text and coordinates, and `max_width` on screenshots you only need to glance
at.
