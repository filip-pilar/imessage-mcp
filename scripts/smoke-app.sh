#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/iMessage MCP.app"
APP_EXEC="$APP/Contents/MacOS/iMessageMCP"
PROXY="$APP/Contents/MacOS/imessage-mcp"
FAKE="$ROOT/Tests/Fixtures/fake-imsg"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/imessage-mcp-smoke.XXXXXX")
CONNECTION="$TEMP/connection.json"
SOCKET="$TEMP/broker.sock"
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP"
}
trap cleanup EXIT INT TERM

[ -x "$APP_EXEC" ] || {
  echo "Build the app first with ./scripts/build-app.sh" >&2
  exit 1
}

IMSG_PATH="$FAKE" \
IMESSAGE_MCP_HOME="$TEMP" \
IMESSAGE_MCP_SOCKET_PATH="$SOCKET" \
"$APP_EXEC" >/dev/null 2>"$TEMP/app.log" &
APP_PID=$!

attempt=0
while [ ! -f "$CONNECTION" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 50 ]; then
    echo "Menu app did not create its broker connection file." >&2
    cat "$TEMP/app.log" >&2
    exit 1
  fi
  sleep 0.1
done

OUTPUT="$TEMP/mcp-output.jsonl"
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"packaged-smoke","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_chats","arguments":{"limit":1}}}'
} | IMESSAGE_MCP_CONNECTION_FILE="$CONNECTION" "$PROXY" >"$OUTPUT"

grep -q '"protocolVersion":"2025-11-25"' "$OUTPUT"
grep -q 'Fixture Chat' "$OUTPUT"
grep -q '"id":2' "$OUTPUT"
echo "Packaged menu app, authenticated broker, stdio proxy, MCP lifecycle, and mocked imsg read passed."
