# Getting started

From nothing to a model tapping buttons on your iPhone. Budget about ten
minutes, most of it waiting on a build and clicking through System Settings.

- [What you need](#what-you-need)
- [1. Build and install](#1-build-and-install)
- [2. Grant permissions](#2-grant-permissions)
- [3. Pair the iPhone](#3-pair-the-iphone)
- [4. Connect your MCP client](#4-connect-your-mcp-client)
- [5. First run](#5-first-run)
- [What to try next](#what-to-try-next)

## What you need

| | |
|---|---|
| **A Mac on macOS 15 or newer** | iPhone Mirroring does not exist before macOS 15. Check with `sw_vers`. |
| **An iPhone on iOS 18 or newer** | Signed into the same Apple Account as the Mac, with two-factor authentication on. |
| **Xcode** | Provides the Swift toolchain that builds this server. The `xcode_*`, `device_*`, and `sim_*` tools need it too; the mirroring tools do not. |
| **An MCP client** | Claude Code, Claude Desktop, Cursor, VS Code, Zed, Codex — anything that speaks MCP over stdio. |

Both devices need Bluetooth and Wi-Fi on and must be near each other. The
iPhone has to be **locked** for mirroring to run — that is Apple's design, not
a limitation of this server.

## 1. Build and install

```sh
git clone https://github.com/nickatnight96/iphone-mirror-mcp.git
cd iphone-mirror-mcp
./install.sh
```

`install.sh` checks your macOS version and toolchain, builds a release binary,
copies it to `~/.local/bin/iphone-mirror-mcp`, runs the permission check, and
prints ready-to-paste configuration for your client.

It installs outside the build directory on purpose: your MCP client stores an
absolute path, and `swift package clean` would otherwise leave that config
pointing at a binary that no longer exists. Use `--prefix DIR` to install
elsewhere, or `--no-copy` to keep it in `.build`.

Prefer to do it by hand:

```sh
swift build -c release
.build/release/iphone-mirror-mcp --version
```

### Or install the MCP bundle

If your client supports MCP bundles (`.mcpb`) and you would rather not install
a Swift toolchain, download `iphone-mirror-mcp.mcpb` from the
[latest release](https://github.com/nickatnight96/iphone-mirror-mcp/releases/latest)
and open it with your client.

The binary inside is universal (Apple silicon + Intel) and ad-hoc signed, but
**not notarized** — this is a free personal project, and notarization requires
a paid Apple Developer account. macOS therefore quarantines it on download.
Clear that first:

```sh
xattr -d com.apple.quarantine ~/Downloads/iphone-mirror-mcp.mcpb
```

Verify the download against the checksum published in the release notes:

```sh
openssl dgst -sha256 ~/Downloads/iphone-mirror-mcp.mcpb
```

Building from source avoids all of this, which is why it is the recommended
path.

## 2. Grant permissions

This is where most setups go wrong, because of one non-obvious rule:

> **Permissions belong to the app that _launches_ the server, not to the
> binary.** macOS attributes synthetic input and screen capture to the parent
> process. If Claude Desktop starts the server, Claude Desktop needs the
> permissions. If you run it from Terminal, Terminal does.

Grant two, in System Settings → Privacy & Security:

| Permission | Where | Why |
|---|---|---|
| **Accessibility** | Privacy & Security → Accessibility | Post taps, swipes, and keystrokes |
| **Screen Recording** | Privacy & Security → Screen & System Audio Recording | Capture the mirroring window |

A third, **Automation → System Events**, is requested the first time it is
needed (resume clicks, activation fallback, notification clicks). Approve the
prompt when it appears.

After granting either permission, **fully quit and reopen the host app**.
macOS only re-reads these at process start, so a running client keeps the old
answer — this is the single most common reason a correct setup still fails.

Verify:

```sh
~/.local/bin/iphone-mirror-mcp doctor
```

```
== iphone-mirror doctor ==
[PASS] Accessibility permission
[PASS] Screen Recording permission
[PASS] Post-event access (synthetic input accepted by macOS)
[PASS] Automation permission (System Events)
Session: connected
Window: id=7980 origin=(621, 66) size=348x766 points
[PASS] iPhone Mirroring is frontmost
[PASS] Capture: 696x1532 px in 0.10s
[PASS] Input delivery: cursor march verified (no clicks posted)
```

`doctor` exits `0` when the permissions pass and `1` when they do not, so you
can use it in a script. It does more than read permission flags: it captures a
real frame and confirms macOS is actually delivering synthetic events, which
catches the case where a permission looks granted but is stale.

## 3. Pair the iPhone

Open **iPhone Mirroring** from Applications and follow the prompts once. Then,
whenever you want to use it:

1. Lock the iPhone (press the side button).
2. Keep it near the Mac.
3. Open iPhone Mirroring — the phone screen appears on the Mac.

If the window says **"iPhone in Use"**, the phone is unlocked. Lock it and the
session resumes. The session pauses every time you physically pick up and
unlock the phone; that is expected.

## 4. Connect your MCP client

**Claude Code:**

```sh
claude mcp add --scope user iphone-mirror -- ~/.local/bin/iphone-mirror-mcp
```

**Anything else** — add a stdio server pointing at the binary:

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/Users/YOU/.local/bin/iphone-mirror-mcp"
    }
  }
}
```

No arguments, no environment variables, no API keys. Use an **absolute path**;
most clients do not expand `~`.

See **[clients.md](clients.md)** for exact snippets and config file locations
for Claude Desktop, Cursor, VS Code, Zed, Codex CLI, Windsurf, and others.

## 5. First run

Restart your client so it picks up the new server, then ask the model:

> Check the iPhone mirroring status, take a screenshot, and tell me what app is open.

That exercises the whole chain: session detection, window capture, and image
return. A good result looks like a screenshot of your phone.

Then try something interactive:

> Open Settings on my iPhone and tell me how much storage is free.

The model will navigate with `launch_app`, read the screen with `read_screen`
or `screenshot`, scroll with `scroll_to`, and report back.

## What to try next

- **[recipes.md](recipes.md)** — worked examples: driving an app, an
  on-device test loop, handling notifications
- **[tools.md](tools.md)** — all 63 tools with parameters
- **[troubleshooting.md](troubleshooting.md)** — when something does not work
- **[limitations.md](limitations.md)** — what this genuinely cannot do, tested
  rather than guessed

## A note on what you are handing over

While the session is active, the model can see and control whatever is on that
iPhone — messages, mail, photos, banking apps. Treat it like handing someone
your unlocked phone. Run it only from clients you trust, and remember you can
end any session instantly by picking up the phone.
