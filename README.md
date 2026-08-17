# iphone-mirror-mcp

[![CI](https://github.com/nickatnight96/iphone-mirror-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/nickatnight96/iphone-mirror-mcp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 15+](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![Listed on mcpservers.org](https://img.shields.io/badge/mcpservers.org-listed-blue)](https://mcpservers.org/servers/nickatnight96/iphone-mirror-mcp)
[![Clones](https://img.shields.io/endpoint?url=https%3A%2F%2Fnickatnight96.github.io%2Fiphone-mirror-mcp%2Ftraffic%2Fbadges%2Fclones.json)](https://github.com/nickatnight96/iphone-mirror-mcp/blob/traffic-data/traffic/history.json)
[![Views](https://img.shields.io/endpoint?url=https%3A%2F%2Fnickatnight96.github.io%2Fiphone-mirror-mcp%2Ftraffic%2Fbadges%2Fviews.json)](https://github.com/nickatnight96/iphone-mirror-mcp/blob/traffic-data/traffic/history.json)

**Let any LLM drive a real iPhone.**

An MCP server that controls a physical iPhone through the built-in macOS
**iPhone Mirroring** app, and automates **Xcode** development testing — build,
test, install, and launch on simulators and devices, then operate the app on
the mirrored screen with taps, swipes, typing, and OCR.

No jailbreak. Nothing installed on the phone. No XCUITest target.

```
run_on_iphone (build → install → launch on the paired iPhone)
   → screenshot / read_screen / tap / paste_text     drive the app on-device
   → wait_for_text / tap with expect / sim_log       assert what the user sees
```

**63 tools.** Works with Claude, GPT, Gemini, local models — anything that
speaks MCP over stdio.

---

## Quick start

```sh
git clone https://github.com/nickatnight96/iphone-mirror-mcp.git
cd iphone-mirror-mcp
./install.sh
```

The installer checks your machine, builds a release binary, verifies
permissions end to end, and prints the exact config for your client.

Then, for Claude Code:

```sh
claude mcp add --scope user iphone-mirror -- ~/.local/bin/iphone-mirror-mcp
```

Or for any other MCP client:

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/Users/YOU/.local/bin/iphone-mirror-mcp"
    }
  }
}
```

Ask your model:

> Take a screenshot of my iPhone and tell me what app is open.

Or grab the `.mcpb` bundle from the
[latest release](https://github.com/nickatnight96/iphone-mirror-mcp/releases/latest)
if your client installs MCP bundles and you would rather skip the toolchain
(see the [caveats](docs/getting-started.md#or-install-the-mcp-bundle) — it is
ad-hoc signed but not notarized).

**→ [Full getting-started guide](docs/getting-started.md)** ·
**[per-client config](docs/clients.md)**

## Requirements

- **macOS 15+** with iPhone Mirroring, paired to an **iOS 18+** iPhone (nearby,
  locked, same Apple Account)
- **Xcode** — for the `xcode_*`, `device_*`, and `sim_*` tools
- **Accessibility** and **Screen Recording** permission, granted to the app
  that *launches* the server (your terminal, or the desktop app hosting your
  client) — [details](docs/getting-started.md#2-grant-permissions)

Check everything at once:

```sh
iphone-mirror-mcp doctor
```

It tests all four permissions, captures a real frame, and confirms macOS is
actually delivering synthetic input — rather than just reading permission
flags. Run it before you suspect anything else.

## What it can do

| | |
|---|---|
| **Session & health** | `status`, `doctor`, `mirror_launch`, `mirror_restart` |
| **See the screen** | `screenshot`, `annotated_screenshot` (every element boxed + numbered), `read_screen` (OCR with tappable centers), `find_text`, `find_image`, `record_screen` |
| **Wait properly** | `wait_for_text`, `wait_for_screen_change`, `scroll_to` |
| **Input** | `tap` (with `expect` verification), `double_tap`, `long_press`, `swipe`, `drag`, `type_text`, `paste_text` (emoji/CJK via clipboard), `read_clipboard`, `press_key`, `shake`, `batch` |
| **Navigate** | `home`, `app_switcher`, `spotlight`, `launch_app`, `open_url` |
| **Notifications** | `notifications`, `notification_click` |
| **Xcode** | `xcode_list`, `xcode_build`, `xcode_test`, `xcresult_attachments` |
| **Real devices** | `run_on_iphone`, `devices`, `device_install`, `device_launch`, `device_info`, `device_apps`, `device_uninstall` |
| **Simulators** | `run_on_sim` plus the full `simctl` belt — push, GPS, privacy grants, status bar, appearance, logs, media |

**→ [Complete tool reference](docs/tools.md)** — all 63, with parameters,
generated from the server's own catalog so it cannot drift.

## Coordinate contract

Every `x`/`y` is a **pixel position in the most recent screenshot**, origin
top-left. At input time the window bounds are re-queried and the pixel maps
proportionally into the current bounds — so a window that moved or was resized
between screenshot and tap still receives the tap in the right place.

## Documentation

| | |
|---|---|
| **[Getting started](docs/getting-started.md)** | Install → permissions → first tap |
| **[Connecting a client](docs/clients.md)** | Claude Code, Claude Desktop, Cursor, VS Code, Zed, Codex, Windsurf |
| **[Tool reference](docs/tools.md)** | All 63 tools and their parameters |
| **[Recipes](docs/recipes.md)** | Driving an app, the on-device test loop, notifications, batching |
| **[Troubleshooting](docs/troubleshooting.md)** | Symptoms → causes → fixes |
| **[Architecture](docs/architecture.md)** | How input actually reaches the phone |
| **[Limitations](docs/limitations.md)** | What this genuinely cannot do |

## Known limitations

Tested, not guessed — the [full list](docs/limitations.md) explains why.

- **Pinch and rotate cannot be synthesized.** Trackpad gestures do not travel
  the CGEvent pipeline; an event tap sees nothing during a physical pinch, so
  there is nothing to reproduce.
- **One phone at a time** — device switching has no scriptable menu.
- **The session pauses whenever the phone is unlocked or picked up.** Apple's
  design; resuming needs it locked again.
- **No accessibility tree** — OCR and template matching are the element model.
  Face ID, Control Center, and hardware buttons are unreachable, and DRM
  content captures black.

## Security

This server can see and control whatever iPhone the Mac is paired with while
mirroring is active. **Treat it like handing your unlocked phone to the
model.** Run it only from clients you trust.

The phone locks the session the moment it is picked up or unlocked physically,
which is a real kill switch. `paste_text` briefly places text on the Mac
clipboard and restores what was there; `read_clipboard` reads it.

See [SECURITY.md](SECURITY.md) for the trust model and how to report a
vulnerability.

## Contributing

Issues and pull requests welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

```sh
scripts/run_tests.sh                    # build + unit/protocol tests + CLI smoke
MIRROR_MCP_LIVE=1 scripts/run_tests.sh  # + live tests (real window, capture, input)
```

## License

[MIT](LICENSE)
