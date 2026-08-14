# Limitations

Tested, not guessed. Everything here was attempted against a live session and
failed for a specific reason — worth reading before you plan around a
capability that does not exist.

## Pinch and rotate cannot be synthesized

Not "not implemented yet" — not possible from a user process.

Trackpad gestures do not travel the CGEvent pipeline at all. An event tap
installed during a *physical* pinch sees nothing, so there is no event shape to
reproduce. Every documented private encoding was tried against a live map and
none delivered.

Workarounds where they exist:

- `double_tap` zooms in on surfaces that support it
- modifier + scroll is not translated by the mirroring app
- ⌘+ / ⌘− are consumed by the Mac app for its own window sizing

## One phone at a time

Device switching lives inside the mirroring app's Settings dialog, which
exposes no scriptable menu. Switching devices is a manual click.

## The session pauses whenever the phone is used

Picking up or unlocking the iPhone pauses mirroring. This is Apple's design.
Resuming needs the phone locked again. There is no way around it, and it means
any long-running automation is interruptible by whoever is holding the phone —
which is arguably the right security property.

## No accessibility tree from the phone

Mirroring streams video, not a view hierarchy. OCR plus template matching *is*
the element model. Consequences:

- Elements are found by their **appearance**, not their identity — a layout
  change breaks selectors in a way a real accessibility ID would not
- Icon-only controls need a cropped template image (`find_image`)
- Very small, low-contrast, or stylized text may not resolve
- There is no "wait for element to exist" beyond polling OCR

`annotated_screenshot` shows exactly what OCR did see, which is the fastest way
to tell a missed element from a misread one.

## Unreachable surfaces

| | Why |
|---|---|
| **Face ID / Touch ID** | Biometrics require physical presence by design |
| **Control Center** | Not reachable through the mirroring window |
| **Hardware buttons** | Volume, side button, and ringer switch are physical |
| **DRM-protected content** | Captures as black frames (Netflix and similar) |

## Clipboard bridging is app-dependent

`read_clipboard` presses ⌘C on the phone and reads what comes back, which is
exact text rather than an OCR guess — but not every field cooperates.
Spotlight, for one, does not bridge the copy back. OCR remains the fallback.

## ASCII-only keystrokes

`type_text` posts real key events and can only express what a US keyboard
layout has keycodes for. Emoji, CJK, and accented characters are skipped and
reported. Use `paste_text` for those — it goes through the clipboard at full
fidelity.

## Localization

Menu-driven navigation (`home`, `app_switcher`, `spotlight`) reaches for the
**View** menu by its English name, with ⌘1/⌘2/⌘3 as a fallback. On a
non-English macOS the fallback carries it, but the primary path will miss.
Pause-overlay detection knows English and French button labels.

If you run a non-English macOS and something in this area misbehaves, that is
a real bug and worth reporting — the fallbacks are not equally exercised.

## Screenshot size

Captures are roughly 700×1500 pixels. That is a meaningful chunk of a context
window if you take many. `max_width` downscales the returned image (coordinates
stay full-resolution, and the caption gives the factor), and `read_screen` is
much cheaper when you only need text and tap targets.

## Platform requirements are hard

- **macOS 15+** — iPhone Mirroring does not exist before it
- **iOS 18+**, same Apple Account, two-factor enabled
- Both devices near each other, Bluetooth and Wi-Fi on
- **Xcode** for the `xcode_*`, `device_*`, and `sim_*` tools (the mirroring
  tools do not need it)
- Apple ships iPhone Mirroring in some regions later than others; if the app is
  absent, nothing here can substitute for it

## Not a substitute for XCUITest

This drives the UI a human sees, which is its point — no test target, no app
changes, works on apps you did not write. But it is slower than XCUITest, has
no view-hierarchy assertions, and is inherently more brittle: it reads pixels.
For your own app's regression suite, XCUITest is still the right tool.
`xcode_test` runs it for you.
