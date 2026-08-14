#!/usr/bin/env python3
"""Regenerate docs/tools.md from the server's own tool catalog.

The reference is generated rather than written so it cannot drift from the
code: it starts the real binary, speaks MCP over stdio, and formats whatever
`tools/list` returns.

    scripts/generate_tool_docs.py           # rewrite docs/tools.md
    scripts/generate_tool_docs.py --check   # exit 1 if it is out of date

`--check` is what CI runs, so a tool added without regenerating the docs
fails the build instead of silently shipping an incomplete reference.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "tools.md"

# Ordered groups. Each tool is claimed by the first group listing it; anything
# unclaimed lands in "Other" so a newly added tool can never be dropped.
GROUPS: list[tuple[str, str, list[str]]] = [
    (
        "Session & health",
        "Start here when anything misbehaves.",
        ["status", "doctor", "mirror_launch", "mirror_restart"],
    ),
    (
        "Screen: capture & reading",
        "Everything that answers *what is on the phone right now*.",
        [
            "screenshot", "annotated_screenshot", "read_screen",
            "find_text", "find_image",
            "wait_for_text", "wait_for_screen_change", "scroll_to",
            "record_screen", "record_start", "record_stop",
        ],
    ),
    (
        "Input: gestures & typing",
        "Every `x`/`y` is a pixel in the most recent screenshot. See "
        "[the coordinate contract](#coordinate-contract).",
        [
            "tap", "tap_text", "tap_image", "double_tap", "long_press",
            "swipe", "drag", "type_text", "paste_text", "read_clipboard",
            "press_key", "shake", "batch",
        ],
    ),
    (
        "Navigation",
        "System-level movement around iOS.",
        ["home", "app_switcher", "spotlight", "launch_app", "open_url"],
    ),
    (
        "Notifications",
        "iPhone notifications surface on the Mac while mirroring is active.",
        ["notifications", "notification_click"],
    ),
    (
        "Xcode: build & test",
        "Build and test any Xcode project or Swift package.",
        ["xcode_list", "xcode_build", "xcode_test", "xcresult_attachments"],
    ),
    (
        "Physical devices",
        "Drive a real, paired iPhone through `devicectl`.",
        [
            "devices", "run_on_iphone", "device_install", "device_launch",
            "device_info", "device_apps", "device_uninstall",
        ],
    ),
    (
        "Simulators",
        "The full `simctl` surface.",
        [
            "run_on_sim", "sim_boot", "sim_install", "sim_launch", "sim_terminate",
            "sim_screenshot", "sim_openurl", "sim_log", "sim_push", "sim_privacy",
            "sim_appearance", "sim_statusbar", "sim_location", "sim_addmedia",
            "sim_apps", "sim_uninstall", "sim_erase",
        ],
    ),
]

HEADER = """<!-- GENERATED FILE — DO NOT EDIT BY HAND.
     Regenerate with: scripts/generate_tool_docs.py -->

# Tool reference

Every tool this server exposes, generated from the server's own catalog so it
always matches the shipped binary.

- **{count} tools** in `iphone-mirror-mcp {version}`
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

"""


def capture_catalog() -> tuple[dict, list[dict]]:
    """Start the built binary and ask it for its tool list over stdio."""
    binary = build_path()
    process = subprocess.Popen(
        [str(binary)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )

    def send(payload: dict) -> None:
        assert process.stdin
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()

    def read() -> dict | None:
        assert process.stdout
        while True:
            line = process.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line)

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                         "clientInfo": {"name": "generate_tool_docs", "version": "1"}}})
        initialized = read()
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        listed = read()
    finally:
        if process.stdin:
            process.stdin.close()
        process.terminate()
        process.wait(timeout=10)

    if not initialized or not listed:
        sys.exit("the server did not respond to initialize/tools/list")
    return initialized["result"]["serverInfo"], listed["result"]["tools"]


def build_path() -> pathlib.Path:
    """Prefer a release build; fall back to debug; build if neither exists."""
    for configuration in ("release", "debug"):
        found = subprocess.run(
            ["swift", "build", "-c", configuration, "--show-bin-path"],
            cwd=ROOT, capture_output=True, text=True,
        )
        if found.returncode == 0:
            candidate = pathlib.Path(found.stdout.strip()) / "iphone-mirror-mcp"
            if candidate.exists():
                return candidate
    sys.exit("no built binary found — run `swift build -c release` first")


def render_parameters(schema: dict) -> str:
    properties = schema.get("properties") or {}
    if not properties:
        return "_No parameters._\n"
    required = set(schema.get("required") or [])
    lines = ["| Parameter | Type | Required | Description |",
             "|---|---|---|---|"]
    # Required parameters first, then alphabetical — the order a caller cares.
    for name in sorted(properties, key=lambda key: (key not in required, key)):
        spec = properties[name] or {}
        kind = spec.get("type", "any")
        if isinstance(kind, list):
            kind = " \\| ".join(str(entry) for entry in kind)
        description = str(spec.get("description", "")).replace("|", "\\|").replace("\n", " ")
        mark = "**yes**" if name in required else "no"
        lines.append(f"| `{name}` | {kind} | {mark} | {description} |")
    return "\n".join(lines) + "\n"


def render(server_info: dict, tools: list[dict]) -> str:
    by_name = {tool["name"]: tool for tool in tools}
    claimed: set[str] = set()
    sections: list[tuple[str, str, list[dict]]] = []

    for title, blurb, names in GROUPS:
        present = [by_name[name] for name in names if name in by_name]
        claimed.update(tool["name"] for tool in present)
        if present:
            sections.append((title, blurb, present))

    leftovers = [tool for tool in tools if tool["name"] not in claimed]
    if leftovers:
        sections.append(("Other", "Not yet categorized in the generator.", leftovers))

    out = [HEADER.format(count=len(tools), version=server_info.get("version", "?"))]

    out.append("## Index\n")
    for title, _, present in sections:
        anchor = title.lower().replace(" ", "-").replace(":", "").replace("&", "")
        anchor = "-".join(part for part in anchor.split("-") if part)
        names = ", ".join(f"[`{tool['name']}`](#{tool['name']})" for tool in present)
        out.append(f"- **[{title}](#{anchor})** — {names}")
    out.append("")

    for title, blurb, present in sections:
        out.append(f"## {title}\n")
        out.append(f"{blurb}\n")
        for tool in present:
            out.append(f"### `{tool['name']}`\n")
            out.append(f"{tool.get('description', '').strip()}\n")
            out.append(render_parameters(tool.get("inputSchema") or {}))
        out.append("")

    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if docs/tools.md is out of date")
    args = parser.parse_args()

    server_info, tools = capture_catalog()
    rendered = render(server_info, tools)

    if args.check:
        if not OUTPUT.exists():
            print(f"{OUTPUT.relative_to(ROOT)} does not exist", file=sys.stderr)
            return 1
        if OUTPUT.read_text() != rendered:
            print(f"{OUTPUT.relative_to(ROOT)} is out of date — "
                  f"run scripts/generate_tool_docs.py", file=sys.stderr)
            return 1
        print(f"{OUTPUT.relative_to(ROOT)} is up to date ({len(tools)} tools)")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(tools)} tools)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
