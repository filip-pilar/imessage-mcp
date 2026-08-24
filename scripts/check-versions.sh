#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

server_version=$(
    sed -n 's/.*serverVersion = "\([^"]*\)".*/\1/p' \
        "$ROOT/Sources/MessageMCPKit/MCPProcessor.swift"
)
app_version=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$ROOT/Resources/Info.plist"
)
plugin_version=$(
    python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
        "$ROOT/distribution/local-private-marketplace/plugins/imessage-mcp/.codex-plugin/plugin.json"
)
plugin_base_version=${plugin_version%%-local.*}
imsg_version=$(
    sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$ROOT/scripts/fetch-imsg.sh"
)

require_value() {
    name=$1
    value=$2
    if [ -z "$value" ]; then
        echo "Could not read $name." >&2
        exit 1
    fi
}

require_equal() {
    name=$1
    actual=$2
    expected=$3
    if [ "$actual" != "$expected" ]; then
        echo "$name is $actual; expected $expected." >&2
        exit 1
    fi
}

require_text() {
    file=$1
    text=$2
    if ! grep -Fq "$text" "$file"; then
        echo "$file does not contain expected version text: $text" >&2
        exit 1
    fi
}

require_value "server version" "$server_version"
require_value "app version" "$app_version"
require_value "plugin version" "$plugin_version"
require_value "imsg version" "$imsg_version"

require_equal "App version" "$app_version" "$server_version"
require_equal "Plugin base version" "$plugin_base_version" "$server_version"

require_text "$ROOT/README.md" "$imsg_version and exposes"
require_text "$ROOT/THIRD_PARTY_NOTICES.md" "\`imsg\` $imsg_version"
require_text "$ROOT/Tests/Fixtures/fake-imsg" "echo \"$imsg_version\""

echo "Version checks passed: app $server_version, plugin $plugin_version, imsg $imsg_version."
