#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DESTINATION="$ROOT/dist/imessage-mcp"

swift build --package-path "$ROOT" --disable-sandbox -c release --product imessage-mcp
BIN=$(swift build --package-path "$ROOT" --disable-sandbox -c release --product imessage-mcp --show-bin-path)
mkdir -p "$ROOT/dist"
cp "$BIN/imessage-mcp" "$DESTINATION"
chmod 755 "$DESTINATION"
codesign --force --sign - "$DESTINATION"
codesign --verify --strict --verbose=2 "$DESTINATION"

echo "$DESTINATION"
