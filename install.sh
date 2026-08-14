#!/usr/bin/env bash
# Build iphone-mirror-mcp, verify the machine can actually run it, and print
# ready-to-paste configuration for whichever MCP client you use.
#
#   ./install.sh                build, check, install, print config
#   ./install.sh --skip-check   skip the permission check
#   ./install.sh --no-copy      leave the binary in .build instead of installing it
#   ./install.sh --prefix DIR   install into DIR (default: ~/.local/bin)
#
set -euo pipefail
cd "$(dirname "$0")"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
# Strip colour when not attached to a terminal (piped into a file or a log).
if [[ ! -t 1 ]]; then BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""; fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
warn() { printf '%s warning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

SKIP_CHECK=0
COPY=1
PREFIX="$HOME/.local/bin"
while (( $# )); do
  case "$1" in
    --skip-check) SKIP_CHECK=1 ;;
    --no-copy) COPY=0 ;;
    --prefix) shift; [[ $# -gt 0 ]] || die "--prefix needs a directory"; PREFIX="$1" ;;
    --prefix=*) PREFIX="${1#*=}" ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option \"$1\" (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------- prereqs ---
step "Checking prerequisites"

[[ "$(uname -s)" == "Darwin" ]] || die "this server drives the macOS iPhone Mirroring app; it only runs on macOS."

macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
if (( macos_major < 15 )); then
  die "macOS 15 or newer is required (iPhone Mirroring does not exist before it); this Mac runs $macos_version."
fi
say "  macOS $macos_version"

if ! command -v swift >/dev/null 2>&1; then
  die "the Swift toolchain was not found. Install Xcode from the App Store, then run:
    xcode-select --install"
fi
say "  $(swift --version 2>/dev/null | head -1)"

if [[ ! -d "/System/Applications/iPhone Mirroring.app" ]]; then
  warn "iPhone Mirroring.app was not found on this Mac. The Xcode and simulator
           tools will still work, but nothing can drive a physical iPhone."
fi

# ------------------------------------------------------------------ build ---
step "Building (release)"
swift build -c release
# --show-bin-path already returns an absolute path.
BUILT="$(swift build -c release --show-bin-path)/iphone-mirror-mcp"
[[ -x "$BUILT" ]] || die "the build finished but no executable landed at $BUILT"
say "  $("$BUILT" --version)"

# Copy out of .build. Clients store an absolute path in their config, and
# `swift package clean` — or just deleting the checkout — would otherwise
# leave that config pointing at nothing.
BINARY="$BUILT"
if (( COPY == 1 )); then
  mkdir -p "$PREFIX"
  install -m 0755 "$BUILT" "$PREFIX/iphone-mirror-mcp"
  BINARY="$PREFIX/iphone-mirror-mcp"
  say "  installed to $BINARY"
else
  warn "keeping the build-directory path; 'swift package clean' will break any
           client configured against it."
fi
say "  $BINARY"

# ------------------------------------------------------------------ check ---
if (( SKIP_CHECK == 0 )); then
  step "Checking permissions"
  say "${DIM}  Permissions belong to the app that LAUNCHES the server — this terminal${RESET}"
  say "${DIM}  right now, and later whichever app hosts your MCP client.${RESET}"
  say ""
  if "$BINARY" doctor; then
    say ""
    say "${GREEN}  All checks passed.${RESET}"
  else
    say ""
    warn "Some checks failed — see above. The server will still install; grant the
           permissions and re-run './install.sh' (or '$BINARY doctor') to confirm."
  fi
fi

# ----------------------------------------------------------------- config ---
step "Configuration"
cat <<EOF
Claude Code — run this:

  claude mcp add --scope user iphone-mirror -- "$BINARY"

Any other MCP client — add this stdio server to its config:

  {
    "mcpServers": {
      "iphone-mirror": {
        "command": "$BINARY"
      }
    }
  }

Config file locations:

  Claude Desktop   ~/Library/Application Support/Claude/claude_desktop_config.json
  Cursor           ~/.cursor/mcp.json
  VS Code (Copilot) .vscode/mcp.json in your workspace, under "servers"
  Zed              ~/.config/zed/settings.json, under "context_servers"
  Codex CLI        ~/.codex/config.toml, as an [mcp_servers.iphone-mirror] table
  Windsurf         ~/.codeium/windsurf/mcp_config.json

Grant the host app Accessibility and Screen Recording permission, then restart
it. See docs/getting-started.md for the full walkthrough, and docs/clients.md
for exact per-client snippets.
EOF
