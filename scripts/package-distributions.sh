#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MARKETPLACE_SOURCE="$ROOT/distribution/local-private-marketplace"
PLUGIN_SOURCE="$MARKETPLACE_SOURCE/plugins/imessage-mcp"
STANDALONE_SOURCE="$ROOT/distribution/standalone"
MARKETPLACE_OUTPUT="$ROOT/dist/imessage-mcp-local-private"
PLUGIN_OUTPUT="$MARKETPLACE_OUTPUT/plugins/imessage-mcp"
STANDALONE_OUTPUT="$ROOT/dist/imessage-mcp-standalone-local-private"

if [ "${1:-}" = "--skip-build" ]; then
    shift
else
    "$ROOT/scripts/build-proxy.sh"
fi

if [ "$#" -ne 0 ]; then
    echo "Usage: ./scripts/package-distributions.sh [--skip-build]" >&2
    exit 2
fi

if [ ! -x "$ROOT/dist/imessage-mcp" ]; then
    echo "Missing dist/imessage-mcp; run without --skip-build first." >&2
    exit 1
fi

"$ROOT/scripts/sync-distributions.sh" --check

/bin/rm -rf "$MARKETPLACE_OUTPUT" "$STANDALONE_OUTPUT"
mkdir -p "$MARKETPLACE_OUTPUT" "$STANDALONE_OUTPUT/bin" "$STANDALONE_OUTPUT/skills"
COPYFILE_DISABLE=1 cp -R "$MARKETPLACE_SOURCE/." "$MARKETPLACE_OUTPUT/"
mkdir -p "$PLUGIN_OUTPUT/bin"
cp "$ROOT/dist/imessage-mcp" "$PLUGIN_OUTPUT/bin/imessage-mcp"
chmod 755 "$PLUGIN_OUTPUT/bin/imessage-mcp" "$PLUGIN_OUTPUT/scripts/launch-imessage-mcp"

cp "$STANDALONE_SOURCE/install" "$STANDALONE_OUTPUT/install"
cp "$STANDALONE_SOURCE/uninstall" "$STANDALONE_OUTPUT/uninstall"
cp "$STANDALONE_SOURCE/README.md" "$STANDALONE_OUTPUT/README.md"
cp "$PLUGIN_SOURCE/scripts/launch-imessage-mcp" "$STANDALONE_OUTPUT/bin/launch-imessage-mcp"
cp "$ROOT/dist/imessage-mcp" "$STANDALONE_OUTPUT/bin/imessage-mcp"
COPYFILE_DISABLE=1 cp -R \
    "$ROOT/.agents/skills/imessage-conversation-watch" \
    "$STANDALONE_OUTPUT/skills/"
chmod 755 \
    "$STANDALONE_OUTPUT/install" \
    "$STANDALONE_OUTPUT/uninstall" \
    "$STANDALONE_OUTPUT/bin/imessage-mcp" \
    "$STANDALONE_OUTPUT/bin/launch-imessage-mcp"

/usr/bin/find "$MARKETPLACE_OUTPUT" "$STANDALONE_OUTPUT" \
    \( -name '.DS_Store' -o -name '._*' \) -delete

/bin/rm -f \
    "$ROOT/dist/imessage-mcp-local-private.zip" \
    "$ROOT/dist/imessage-mcp-standalone-local-private.zip"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$MARKETPLACE_OUTPUT" "$ROOT/dist/imessage-mcp-local-private.zip"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$STANDALONE_OUTPUT" "$ROOT/dist/imessage-mcp-standalone-local-private.zip"

echo "$MARKETPLACE_OUTPUT"
echo "$STANDALONE_OUTPUT"
