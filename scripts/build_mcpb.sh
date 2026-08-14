#!/usr/bin/env bash
# Build an MCP Bundle (.mcpb) — a zip containing a universal binary and a
# manifest — so clients that support bundles can install without a Swift
# toolchain, and so the server can be listed in the official MCP registry
# (which has no source/SwiftPM package type; mcpb is the only fit for a
# compiled binary).
#
#   scripts/build_mcpb.sh              build dist/iphone-mirror-mcp.mcpb
#   scripts/build_mcpb.sh --update-server-json   also refresh server.json
#
# Prints the SHA-256 the registry requires in server.json.
set -euo pipefail
cd "$(dirname "$0")/.."

UPDATE_SERVER_JSON=0
for argument in "$@"; do
  case "$argument" in
    --update-server-json) UPDATE_SERVER_JSON=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option \"$argument\"" >&2; exit 2 ;;
  esac
done

VERSION="$(grep -o 'version = "[^"]*"' Sources/MirrorServer/MirrorMCPServer.swift | head -1 | cut -d'"' -f2)"
[[ -n "$VERSION" ]] || { echo "could not read the version from MirrorMCPServer.swift" >&2; exit 1; }
echo "==> Version $VERSION"

# A universal binary so the bundle runs on both Apple silicon and Intel Macs.
echo "==> Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BUILT="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/iphone-mirror-mcp"
[[ -x "$BUILT" ]] || { echo "no binary at $BUILT" >&2; exit 1; }
lipo -info "$BUILT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/server"
cp "$BUILT" "$STAGE/server/iphone-mirror-mcp"
chmod +x "$STAGE/server/iphone-mirror-mcp"

# Ad-hoc signature. This does NOT notarize — users may still need to clear the
# quarantine attribute on download (documented in docs/getting-started.md) —
# but an unsigned binary is rejected outright on Apple silicon, so this is the
# difference between "warns" and "will not run at all".
echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$STAGE/server/iphone-mirror-mcp"
codesign --verify --verbose=1 "$STAGE/server/iphone-mirror-mcp" 2>&1 | sed 's/^/    /'

sed "s/__VERSION__/$VERSION/g" mcpb/manifest.json > "$STAGE/manifest.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$STAGE/manifest.json"
cp README.md LICENSE "$STAGE/"

mkdir -p dist
BUNDLE="$PWD/dist/iphone-mirror-mcp.mcpb"
rm -f "$BUNDLE"
echo "==> Packing $BUNDLE"
( cd "$STAGE" && zip -qr "$BUNDLE" . -x '.*' )

SHA="$(openssl dgst -sha256 "$BUNDLE" | awk '{print $2}')"
SIZE="$(du -h "$BUNDLE" | cut -f1)"
echo "==> Built $BUNDLE ($SIZE)"
echo "    sha256: $SHA"

if (( UPDATE_SERVER_JSON == 1 )); then
  URL="https://github.com/nickatnight96/iphone-mirror-mcp/releases/download/v$VERSION/iphone-mirror-mcp.mcpb"
  python3 - "$VERSION" "$URL" "$SHA" <<'PY'
import json, sys
version, url, sha = sys.argv[1:4]
with open("server.json") as handle:
    document = json.load(handle)
document["version"] = version
for package in document.get("packages", []):
    if package.get("registryType") == "mcpb":
        package["identifier"] = url
        package["fileSha256"] = sha
        package["version"] = version
with open("server.json", "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
print("    server.json updated")
PY
fi
