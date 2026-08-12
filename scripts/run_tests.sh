#!/usr/bin/env bash
# Build + verify pipeline for iphone-mirror-mcp.
# Usage: scripts/run_tests.sh
#   MIRROR_MCP_LIVE=1 scripts/run_tests.sh   # additionally runs live tests that
#                                            # need the iPhone Mirroring window
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== swift build =="
swift build

echo "== swift test =="
if [[ "${MIRROR_MCP_LIVE:-0}" == "1" ]]; then
  MIRROR_MCP_LIVE=1 swift test
else
  swift test
fi

echo "== ALL TESTS PASSED =="
