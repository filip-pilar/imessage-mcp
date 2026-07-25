#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/iMessage MCP.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="${TMPDIR:-/tmp}/iMessageMCP.iconset"

"$ROOT/scripts/fetch-imsg.sh"
swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64
BIN=$(swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$APP" "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES/imsg" "$ICONSET"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$BIN/iMessageMCP" "$MACOS/iMessageMCP"
cp "$BIN/imessage-mcp" "$MACOS/imessage-mcp"
cp -R "$ROOT/Vendor/imsg/." "$RESOURCES/imsg/"

swift "$ROOT/scripts/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$MACOS/imessage-mcp"
codesign --force --sign - --entitlements "$ROOT/Resources/iMessageMCP.entitlements" "$MACOS/iMessageMCP"
codesign --force --sign - --options runtime --entitlements "$ROOT/Resources/iMessageMCP.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"
