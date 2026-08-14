#!/usr/bin/env bash
# Build an MCP Bundle (.mcpb) — a zip containing a universal binary and a
# manifest — so clients that support bundles can install without a Swift
# toolchain, and so the server can be listed in the official MCP registry
# (which has no source/SwiftPM package type; mcpb is the only fit for a
# compiled binary).
#
#   scripts/build_mcpb.sh                       build dist/iphone-mirror-mcp.mcpb
#   scripts/build_mcpb.sh --update-server-json  also refresh server.json
#   scripts/build_mcpb.sh --from-release vX.Y.Z point server.json at a PUBLISHED
#                                               release and record ITS checksum
#
# Use --from-release after publishing. A locally built bundle is not
# byte-identical to the one CI produced, so a local checksum is the wrong thing
# to advertise: MCP clients verify the hash before installing, and a mismatch
# fails the install outright.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_URL="https://github.com/nickatnight96/iphone-mirror-mcp"

# Rewrites server.json in place: <version> <download url> <sha256>
update_server_json() {
  UPDATE_VERSION="$1" UPDATE_URL="$2" UPDATE_SHA="$3" python3 - <<'PYTHON'
import json, os

version = os.environ["UPDATE_VERSION"]
url = os.environ["UPDATE_URL"]
sha = os.environ["UPDATE_SHA"]

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
PYTHON
}

UPDATE_SERVER_JSON=0
FROM_RELEASE=""
while (( $# )); do
  case "$1" in
    --update-server-json) UPDATE_SERVER_JSON=1 ;;
    --from-release) shift; [[ $# -gt 0 ]] || { echo "--from-release needs a tag" >&2; exit 2; }; FROM_RELEASE="$1" ;;
    --from-release=*) FROM_RELEASE="${1#*=}" ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option \"$1\"" >&2; exit 2 ;;
  esac
  shift
done

# ------------------------------------------- sync against a published release
if [[ -n "$FROM_RELEASE" ]]; then
  echo "==> Syncing server.json from release $FROM_RELEASE"
  TEMP="$(mktemp -d)"
  trap 'rm -rf "$TEMP"' EXIT
  gh release download "$FROM_RELEASE" --pattern '*.mcpb' \
    --output "$TEMP/bundle.mcpb" --clobber
  SHA="$(openssl dgst -sha256 "$TEMP/bundle.mcpb" | awk '{print $2}')"
  echo "    sha256: $SHA"
  update_server_json "${FROM_RELEASE#v}" \
    "$REPO_URL/releases/download/$FROM_RELEASE/iphone-mirror-mcp.mcpb" "$SHA"
  exit 0
fi

# ------------------------------------------------------------------- version
VERSION="$(grep -o 'version = "[^"]*"' Sources/MirrorServer/MirrorMCPServer.swift | head -1 | cut -d'"' -f2)"
[[ -n "$VERSION" ]] || { echo "could not read the version from MirrorMCPServer.swift" >&2; exit 1; }
echo "==> Version $VERSION"

# --------------------------------------------------------------------- build
# A universal binary so the bundle runs on both Apple silicon and Intel Macs.
#
# Built one architecture at a time into separate scratch paths, then merged
# with lipo. SwiftPM's own multi-arch mode (`--arch arm64 --arch x86_64`)
# routes through the Xcode build system and fails on a clean machine with
# "Unexpected duplicate tasks" / "missing target configuration" — it passed
# locally only off a warm build directory. Separate scratch paths cannot
# collide, so this path is deterministic.
echo "==> Building universal binary (arm64 + x86_64)"
SLICES=()
for arch in arm64 x86_64; do
  echo "    building $arch"
  swift build -c release --arch "$arch" --scratch-path ".build-$arch"
  slice="$(swift build -c release --arch "$arch" --scratch-path ".build-$arch" --show-bin-path)/iphone-mirror-mcp"
  [[ -x "$slice" ]] || { echo "no $arch binary at $slice" >&2; exit 1; }
  SLICES+=("$slice")
done

BUILT="$PWD/.build-universal/iphone-mirror-mcp"
mkdir -p "$(dirname "$BUILT")"
lipo -create -output "$BUILT" "${SLICES[@]}"
chmod +x "$BUILT"
lipo -info "$BUILT"

# --------------------------------------------------------------------- stage
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/server"
cp "$BUILT" "$STAGE/server/iphone-mirror-mcp"
chmod +x "$STAGE/server/iphone-mirror-mcp"

# Ad-hoc signature. This does NOT notarize — users may still need to clear the
# quarantine attribute after downloading (documented in docs/getting-started.md)
# — but an unsigned binary is rejected outright on Apple silicon, so this is the
# difference between "warns" and "will not run at all".
echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$STAGE/server/iphone-mirror-mcp"
codesign --verify --verbose=1 "$STAGE/server/iphone-mirror-mcp" 2>&1 | sed 's/^/    /'

sed "s/__VERSION__/$VERSION/g" mcpb/manifest.json > "$STAGE/manifest.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$STAGE/manifest.json"
cp README.md LICENSE "$STAGE/"

# ---------------------------------------------------------------------- pack
mkdir -p dist
BUNDLE="$PWD/dist/iphone-mirror-mcp.mcpb"
rm -f "$BUNDLE"
echo "==> Packing $BUNDLE"
( cd "$STAGE" && zip -qr "$BUNDLE" . -x '.*' )

SHA="$(openssl dgst -sha256 "$BUNDLE" | awk '{print $2}')"
echo "==> Built $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
echo "    sha256: $SHA"

if (( UPDATE_SERVER_JSON == 1 )); then
  update_server_json "$VERSION" \
    "$REPO_URL/releases/download/v$VERSION/iphone-mirror-mcp.mcpb" "$SHA"
  echo "    NOTE: that is this LOCAL build's checksum. After publishing, run:"
  echo "          scripts/build_mcpb.sh --from-release v$VERSION"
fi
