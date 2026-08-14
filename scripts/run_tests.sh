#!/usr/bin/env bash
# Build + verify pipeline for iphone-mirror-mcp.
# Usage: scripts/run_tests.sh
#   MIRROR_MCP_LIVE=1 scripts/run_tests.sh   # additionally runs live tests that
#                                            # need the iPhone Mirroring window
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== shell script syntax =="
for script in install.sh scripts/*.sh; do
  bash -n "$script"
  echo "  ok $script"
done

echo "== swift build =="
swift build

echo "== swift test =="
if [[ "${MIRROR_MCP_LIVE:-0}" == "1" ]]; then
  MIRROR_MCP_LIVE=1 swift test
else
  swift test
fi

# The CLI is what a user runs by hand to tell a working install from a broken
# one, so verify the real binary — not just the parser unit tests — answers.
echo "== cli smoke =="
BINARY="$(swift build --show-bin-path)/iphone-mirror-mcp"
"$BINARY" --version | grep -q 'iphone-mirror-mcp' || { echo "--version did not identify the binary"; exit 1; }
echo "  ok --version: $("$BINARY" --version)"
"$BINARY" --help | grep -q 'doctor' || { echo "--help did not mention doctor"; exit 1; }
echo "  ok --help"
# An unrecognized flag must fail loudly rather than silently starting a server
# that then blocks forever on stdin.
if "$BINARY" --not-a-real-flag >/dev/null 2>&1; then
  echo "an unknown flag exited 0; it must be rejected"; exit 1
fi
echo "  ok unknown flag rejected (exit 2)"

echo "== version consistency =="
# The version is compiled into the binary, advertised in server.json, and
# stamped into the bundle manifest at pack time. A mismatch means the registry
# would point at a download that disagrees with itself.
SOURCE_VERSION="$("$BINARY" --version | awk '{print $2}')"
SERVER_JSON_VERSION="$(python3 -c 'import json; print(json.load(open("server.json"))["version"])')"
if [[ "$SOURCE_VERSION" != "$SERVER_JSON_VERSION" ]]; then
  echo "version mismatch: binary is $SOURCE_VERSION, server.json says $SERVER_JSON_VERSION"; exit 1
fi
PKG_VERSION="$(python3 -c 'import json; print(json.load(open("server.json"))["packages"][0]["version"])')"
if [[ "$SOURCE_VERSION" != "$PKG_VERSION" ]]; then
  echo "version mismatch: binary is $SOURCE_VERSION, server.json package says $PKG_VERSION"; exit 1
fi
# The download URL must carry the same version, or the registry serves the
# wrong artifact for this entry.
if ! python3 -c 'import json,sys; sys.exit(0 if "v"+json.load(open("server.json"))["version"] in json.load(open("server.json"))["packages"][0]["identifier"] else 1)'; then
  echo "server.json package URL does not reference v$SOURCE_VERSION"; exit 1
fi
echo "  ok version $SOURCE_VERSION consistent across binary, server.json, and package URL"

echo "== tool reference =="
python3 scripts/generate_tool_docs.py --check

echo "== ALL TESTS PASSED =="
