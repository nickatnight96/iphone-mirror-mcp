# Connecting a client

This is an ordinary **stdio MCP server**. It takes no arguments, no
environment variables, and no API keys — any client that can launch a local
binary can use it, whatever model sits behind that client.

Everything below reduces to the same thing:

```
command: /Users/YOU/.local/bin/iphone-mirror-mcp
args:    (none)
```

Two rules that apply everywhere:

1. **Use an absolute path.** Most clients do not expand `~`.
2. **The host app needs the permissions**, not the binary — see
   [getting-started.md](getting-started.md#2-grant-permissions). After
   granting them, fully quit and reopen the client.

`./install.sh` prints your exact path; or run `which iphone-mirror-mcp` if it
is on your `PATH`.

---

## Claude Code

```sh
claude mcp add --scope user iphone-mirror -- ~/.local/bin/iphone-mirror-mcp
```

`--scope user` makes it available in every project. Use `--scope project` to
commit it to a repo instead. Verify with `claude mcp list`.

Terminal-launched, so **Terminal** (or iTerm, Ghostty, …) is the app that
needs Accessibility and Screen Recording.

## Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/Users/YOU/.local/bin/iphone-mirror-mcp"
    }
  }
}
```

Quit Claude Desktop completely (⌘Q — closing the window is not enough) and
reopen. **Claude Desktop** is the app that needs the permissions.

## Cursor

`~/.cursor/mcp.json` for every project, or `.cursor/mcp.json` for one:

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/Users/YOU/.local/bin/iphone-mirror-mcp"
    }
  }
}
```

## VS Code (GitHub Copilot)

`.vscode/mcp.json` in your workspace — note the top-level key is `servers`,
not `mcpServers`:

```json
{
  "servers": {
    "iphone-mirror": {
      "type": "stdio",
      "command": "/Users/YOU/.local/bin/iphone-mirror-mcp"
    }
  }
}
```

For every workspace, run **MCP: Open User Configuration** from the Command
Palette and add the same block there. Tools appear in Agent mode.

## Zed

`~/.config/zed/settings.json` — the key is `context_servers`:

```json
{
  "context_servers": {
    "iphone-mirror": {
      "command": "/Users/YOU/.local/bin/iphone-mirror-mcp",
      "args": [],
      "env": {}
    }
  }
}
```

## Codex CLI

`~/.codex/config.toml`:

```toml
[mcp_servers.iphone-mirror]
command = "/Users/YOU/.local/bin/iphone-mirror-mcp"
args = []
```

## Windsurf

`~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/Users/YOU/.local/bin/iphone-mirror-mcp"
    }
  }
}
```

## Anything else

The `mcpServers` shape above is what most clients converged on. If yours
differs, it still only needs the command and an empty argument list. To drive
the server directly from your own code, use an MCP SDK
([Python](https://github.com/modelcontextprotocol/python-sdk),
[TypeScript](https://github.com/modelcontextprotocol/typescript-sdk),
[Swift](https://github.com/modelcontextprotocol/swift-sdk)) with a stdio
transport pointing at the binary.

---

## Checking it worked

Ask the model to call `status`, or `doctor` if anything looks off. Both are
read-only and safe to run any time.

If the client reports the server failed to start, run the binary by hand
first:

```sh
/Users/YOU/.local/bin/iphone-mirror-mcp --version
```

A version string means the binary is fine and the problem is in the client
config. Note that running it with **no arguments** is *supposed* to look like
it hangs — that is a stdio server waiting for a JSON-RPC frame on stdin, not a
crash. Press ⌃C.

More symptoms and fixes: [troubleshooting.md](troubleshooting.md).
