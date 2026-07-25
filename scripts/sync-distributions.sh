#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/.agents/skills/imessage-conversation-watch"
DESTINATION="$ROOT/distribution/local-private-marketplace/plugins/imessage-mcp/skills/imessage-conversation-watch"

if [ "${1:-}" = "--check" ]; then
    if [ ! -d "$DESTINATION" ]; then
        echo "Plugin skill copy is missing. Run ./scripts/sync-distributions.sh." >&2
        exit 1
    fi
    diff -ru "$SOURCE" "$DESTINATION"
    exit 0
fi

if [ "$#" -ne 0 ]; then
    echo "Usage: ./scripts/sync-distributions.sh [--check]" >&2
    exit 2
fi

/bin/rm -rf "$DESTINATION"
mkdir -p "$(dirname -- "$DESTINATION")"
cp -R "$SOURCE" "$DESTINATION"
echo "Synchronized $DESTINATION"
