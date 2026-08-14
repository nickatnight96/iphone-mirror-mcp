# Troubleshooting

Start here:

```sh
~/.local/bin/iphone-mirror-mcp doctor
```

`doctor` tests the whole chain end to end — all four permissions, a real frame
capture, and whether macOS is actually delivering synthetic input — rather
than just reading permission flags. Most problems are identifiable from its
output alone. Include it when you file an issue.

- [The client says the server failed to start](#the-client-says-the-server-failed-to-start)
- [Permissions look granted but nothing works](#permissions-look-granted-but-nothing-works)
- [Session is paused and will not resume](#session-is-paused-and-will-not-resume)
- [Taps land in the wrong place](#taps-land-in-the-wrong-place)
- [Taps do nothing at all](#taps-do-nothing-at-all)
- [Swipes do nothing, or the session freezes](#swipes-do-nothing-or-the-session-freezes)
- [Typing drops characters](#typing-drops-characters)
- [Screenshots are black](#screenshots-are-black)
- [Screenshots use too much context](#screenshots-use-too-much-context)
- [OCR cannot find text that is clearly visible](#ocr-cannot-find-text-that-is-clearly-visible)
- [Xcode and simulator tools fail](#xcode-and-simulator-tools-fail)
- [Filing a good issue](#filing-a-good-issue)

---

## The client says the server failed to start

Run the binary directly:

```sh
/Users/YOU/.local/bin/iphone-mirror-mcp --version
```

| What happens | Meaning |
|---|---|
| Prints a version | The binary is fine — the problem is your client config |
| `command not found` | Wrong path, or you used `~` where the client needs an absolute path |
| `Bad CPU type` | Binary built for a different architecture; rebuild with `./install.sh` |
| Nothing, appears to hang | **This is correct.** A stdio server waits for input on stdin. Press ⌃C |

The last row catches people constantly: no output is the *expected* behaviour
when you launch an MCP server by hand.

If the binary works, check the client config for: a relative path, `~` instead
of `/Users/you`, a stale path into `.build/` that `swift package clean`
deleted, or `mcpServers` where that client wants `servers` (VS Code) or
`context_servers` (Zed). See [clients.md](clients.md).

## Permissions look granted but nothing works

Almost always one of these three:

**The wrong app is authorized.** macOS attributes input and capture to the
process that *launched* the server. Claude Desktop starting the server means
Claude Desktop needs the permissions — not Terminal, not the binary. Check
which app is actually listed in System Settings.

**The host app was not restarted.** macOS reads these permissions at process
start. A running app keeps the old answer no matter what the settings pane
shows. Fully quit (⌘Q, not just closing the window) and reopen.

**The permission is stale after an update.** Rebuilding the binary or updating
the host app can invalidate an existing grant while it still displays as
enabled. Toggle it off and back on in System Settings, then restart the app.

`doctor`'s `Post-event access` line is the real test — it reports whether
macOS is accepting synthetic events from this process right now, which is a
stronger signal than the Accessibility checkbox.

## Session is paused and will not resume

The session pauses whenever the iPhone is picked up or unlocked. That is
Apple's design and cannot be worked around.

1. **Lock the iPhone** — press the side button. This is the fix in most cases.
2. Keep it near the Mac with Bluetooth and Wi-Fi on.
3. Call `mirror_launch`, or click **Resume** in the window.
4. Still stuck? `mirror_restart` quits and relaunches the app.

"iPhone in Use" means the phone is unlocked. Nothing will work until it is
locked again.

## Taps land in the wrong place

Coordinates are pixels **in the most recent screenshot**. The usual causes:

- **A stale screenshot.** The screen changed after you captured it. Take a
  fresh one before computing coordinates.
- **A downscaled image.** If you passed `max_width`, the returned image is
  smaller than the coordinate space. The caption states the factor — multiply
  coordinates you read off that image by it before tapping.
- **Guessed coordinates.** Use `read_screen`, `find_text`, or
  `annotated_screenshot` to get real element centers instead of estimating.

You do *not* need to worry about the window moving or being resized between
screenshot and tap — bounds are re-queried at input time and the pixel is
remapped proportionally.

## Taps do nothing at all

- Check `status`. A paused session accepts no input.
- Something else may have taken focus. Input tools re-assert frontmost before
  posting, but a focus change mid-call can still interfere. Retry.
- After an activation that changes focus, the window's unhide animation
  discards all input for about 1.5 seconds. The server waits this out; if you
  are driving unusually fast, add a short pause.
- Face ID, Control Center, and hardware buttons are not reachable at all — see
  [limitations.md](limitations.md).

## Swipes do nothing, or the session freezes

If video still streams but no input registers, the session is wedged. Call
`mirror_restart`.

This is why the gesture engine materializes an entire phase sequence before
posting anything: a gesture cut off partway leaves iOS tracking a finger that
never lifted, and SpringBoard stops accepting input until the app restarts. If
you can reproduce a wedge through the tools rather than by killing the process
mid-gesture, that is a bug worth reporting.

For scrolling that will not move: some surfaces need the pointer over the
scrollable region specifically, so swipe through the middle of the content
rather than near an edge.

## Typing drops characters

`type_text` sends real keystrokes and is **ASCII-only** — emoji, CJK, and
accented characters have no keycode and are skipped, which the tool reports.

Use `paste_text` for anything non-ASCII or long. It goes through the bridged
clipboard at full fidelity and restores whatever you had on the Mac clipboard
afterwards.

Also make sure a text field is actually focused — tap it first.

## Screenshots are black

- **DRM-protected content** (Netflix and friends) captures black. Not fixable.
- No Screen Recording permission, or a stale grant — see above.
- A paused session may capture the overlay rather than the phone screen.

## Screenshots use too much context

Full-resolution captures are around 700×1500 pixels. If that is eating your
context window, pass `max_width` to `screenshot` — but remember coordinates
stay in full-resolution space, and the caption tells you the scale factor to
multiply by.

For finding elements, `read_screen` is usually far cheaper than an image: it
returns text with tappable centers and no pixels at all.

## OCR cannot find text that is clearly visible

There is no accessibility tree from the phone, so OCR is the element model and
it has real limits.

- Try `find_text` with `exact: false` for a substring match.
- Icons with no text are invisible to OCR — use `find_image` / `tap_image`
  with a crop from a previous screenshot at full resolution.
- Very small, low-contrast, or stylized text may not resolve. Scroll it into a
  clearer position, or match a cropped image instead.
- `annotated_screenshot` shows exactly what OCR *did* see, boxed and numbered.
  It is the fastest way to tell "OCR missed it" from "the model misread it".

## Xcode and simulator tools fail

These need Xcode and its command line tools:

```sh
xcode-select -p          # should print an Xcode path
xcodebuild -version
xcrun simctl list devices
```

If `xcode-select -p` points at the standalone CLI tools rather than Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

For `run_on_iphone`, the device must be paired and trusted for development,
and your scheme needs a valid signing identity. Run `devices` to confirm the
iPhone is visible to `devicectl` — that is a different pairing from the
mirroring session, and one can work while the other does not.

## Filing a good issue

Include:

1. The full output of `iphone-mirror-mcp doctor`
2. `sw_vers` and `iphone-mirror-mcp --version`
3. Your client and how it launches the server
4. The tool call you made and what came back
5. What you expected instead

Issues: https://github.com/nickatnight96/iphone-mirror-mcp/issues
