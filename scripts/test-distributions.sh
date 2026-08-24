#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MARKETPLACE_SOURCE="$ROOT/distribution/local-private-marketplace"
PLUGIN_SOURCE="$MARKETPLACE_SOURCE/plugins/imessage-mcp"
PLUGIN_ARCHIVE="$ROOT/dist/imessage-mcp-local-private.zip"
STANDALONE_ARCHIVE="$ROOT/dist/imessage-mcp-standalone-local-private.zip"
CODEX_SKILLS_ROOT=${CODEX_SKILLS_ROOT:-"${CODEX_HOME:-$HOME/.codex}/skills"}
PLUGIN_CREATOR="$CODEX_SKILLS_ROOT/.system/plugin-creator"
SKILL_VALIDATOR="$CODEX_SKILLS_ROOT/.system/skill-creator/scripts/quick_validate.py"
plugin_version=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
    "$PLUGIN_SOURCE/.codex-plugin/plugin.json")

"$ROOT/scripts/sync-distributions.sh" --check
python3 "$PLUGIN_CREATOR/scripts/validate_plugin.py" "$PLUGIN_SOURCE"
python3 "$SKILL_VALIDATOR" "$PLUGIN_SOURCE/skills/imessage-conversation-watch"
marketplace_name=$(python3 "$PLUGIN_CREATOR/scripts/read_marketplace_name.py" \
    --marketplace-path "$MARKETPLACE_SOURCE/.agents/plugins/marketplace.json")
test "$marketplace_name" = "imessage-mcp-local"

"$ROOT/scripts/package-distributions.sh"
test -s "$PLUGIN_ARCHIVE"
test -s "$STANDALONE_ARCHIVE"

for archive in "$PLUGIN_ARCHIVE" "$STANDALONE_ARCHIVE"; do
    if unzip -Z1 "$archive" | grep -Eq '(^|/)(__MACOSX/|\\._|\\.DS_Store$)'; then
        echo "Archive contains AppleDouble or Finder metadata: $archive" >&2
        exit 1
    fi
done

test_root=$(mktemp -d "${TMPDIR:-/tmp}/imessage-mcp-distribution-test.XXXXXX")
trap '/bin/rm -rf "$test_root"' EXIT HUP INT TERM
unpacked="$test_root/unpacked"
mkdir -p "$unpacked"
ditto -x -k "$PLUGIN_ARCHIVE" "$unpacked"
ditto -x -k "$STANDALONE_ARCHIVE" "$unpacked"

marketplace="$unpacked/imessage-mcp-local-private"
plugin="$marketplace/plugins/imessage-mcp"
standalone="$unpacked/imessage-mcp-standalone-local-private"
python3 "$PLUGIN_CREATOR/scripts/validate_plugin.py" "$plugin"

test -x "$plugin/bin/imessage-mcp"
test -x "$plugin/scripts/launch-imessage-mcp"
test -x "$standalone/install"
test -x "$standalone/uninstall"
lipo "$plugin/bin/imessage-mcp" -verify_arch arm64 x86_64
codesign --verify --strict "$plugin/bin/imessage-mcp"
codesign --verify --strict "$standalone/bin/imessage-mcp"
cmp "$ROOT/dist/imessage-mcp" "$plugin/bin/imessage-mcp"
cmp "$plugin/bin/imessage-mcp" "$standalone/bin/imessage-mcp"
cmp "$plugin/scripts/launch-imessage-mcp" \
    "$standalone/bin/launch-imessage-mcp"
diff -ru "$ROOT/.agents/skills/imessage-conversation-watch" \
    "$standalone/skills/imessage-conversation-watch"

launcher_result=$(IMESSAGE_MCP_SKIP_APP_LAUNCH=1 \
    IMESSAGE_MCP_PROXY_PATH=/usr/bin/printf \
    "$plugin/scripts/launch-imessage-mcp" "launcher-ok")
test "$launcher_result" = "launcher-ok"

isolated_codex_home="$test_root/codex-home"
mkdir -p "$isolated_codex_home"
project="$test_root/project"
mkdir -p "$project/.codex"
echo 'model = "test-model"' > "$project/.codex/config.toml"

CODEX_HOME="$isolated_codex_home" "$standalone/install" --project "$project"
grep -Fq 'model = "test-model"' "$project/.codex/config.toml"
grep -Fq '[mcp_servers.imessage]' "$project/.codex/config.toml"
test -x "$project/.codex/imessage-mcp/bin/imessage-mcp"
test -f "$project/.agents/skills/imessage-conversation-watch/SKILL.md"

CODEX_HOME="$isolated_codex_home" \
    "$standalone/install" --project "$project" --mcp-only
definition_count=$(grep -c '^\[mcp_servers\.imessage\]$' "$project/.codex/config.toml")
test "$definition_count" -eq 1

config_conflict="$test_root/config-conflict"
mkdir -p "$config_conflict/.codex"
printf '%s\n' '[mcp_servers.imessage]' 'command = "/other/proxy"' \
    > "$config_conflict/.codex/config.toml"
if CODEX_HOME="$isolated_codex_home" \
    "$standalone/install" --project "$config_conflict" >/dev/null 2>&1; then
    echo "Installer overwrote a conflicting MCP definition." >&2
    exit 1
fi
grep -Fq 'command = "/other/proxy"' "$config_conflict/.codex/config.toml"

skill_conflict="$test_root/skill-conflict"
mkdir -p "$skill_conflict/.agents/skills/imessage-conversation-watch"
echo "different skill" \
    > "$skill_conflict/.agents/skills/imessage-conversation-watch/SKILL.md"
if CODEX_HOME="$isolated_codex_home" \
    "$standalone/install" --project "$skill_conflict" >/dev/null 2>&1; then
    echo "Installer overwrote a conflicting skill." >&2
    exit 1
fi
test ! -e "$skill_conflict/.codex/config.toml"

quoted_project="$test_root/project \"quoted\""
mkdir -p "$quoted_project"
CODEX_HOME="$isolated_codex_home" \
    "$standalone/install" --project "$quoted_project" --mcp-only
grep -Fq '\"quoted\"' "$quoted_project/.codex/config.toml"
CODEX_HOME="$isolated_codex_home" \
    "$standalone/uninstall" --project "$quoted_project"
test ! -d "$quoted_project/.codex/imessage-mcp"
test "$(grep -c '^\[mcp_servers\.imessage\]$' \
    "$quoted_project/.codex/config.toml" || true)" -eq 0

CODEX_HOME="$isolated_codex_home" codex plugin marketplace add "$marketplace"
install_result=$(CODEX_HOME="$isolated_codex_home" \
    codex plugin add imessage-mcp@imessage-mcp-local --json)
printf '%s\n' "$install_result" | grep -Fq "\"version\": \"$plugin_version\""
printf '%s\n' "$install_result" | grep -Fq '"name": "imessage-mcp"'

collision_project="$test_root/collision"
mkdir -p "$collision_project"
if CODEX_HOME="$isolated_codex_home" \
    "$standalone/install" --project "$collision_project" >/dev/null 2>&1; then
    echo "Standalone installer allowed an enabled plugin collision." >&2
    exit 1
fi
test ! -e "$collision_project/.codex/config.toml"
CODEX_HOME="$isolated_codex_home" "$standalone/install" \
    --project "$collision_project" --allow-plugin-overlap
(
    cd "$collision_project"
    CODEX_HOME="$isolated_codex_home" codex mcp list --json >/dev/null
)

CODEX_HOME="$isolated_codex_home" \
    codex plugin remove imessage-mcp@imessage-mcp-local --json >/dev/null
CODEX_HOME="$isolated_codex_home" \
    codex plugin marketplace remove imessage-mcp-local --json >/dev/null
test -x "$project/.codex/imessage-mcp/bin/imessage-mcp"
test -f "$project/.agents/skills/imessage-conversation-watch/SKILL.md"
grep -Fq '[mcp_servers.imessage]' "$project/.codex/config.toml"

CODEX_HOME="$isolated_codex_home" codex plugin marketplace add "$marketplace"
CODEX_HOME="$isolated_codex_home" \
    codex plugin add imessage-mcp@imessage-mcp-local --json >/dev/null
CODEX_HOME="$isolated_codex_home" "$standalone/uninstall" --project "$project"
test ! -d "$project/.codex/imessage-mcp"
test ! -e "$project/.agents/skills/imessage-conversation-watch"
test "$(grep -c '^\[mcp_servers\.imessage\]$' \
    "$project/.codex/config.toml" || true)" -eq 0
CODEX_HOME="$isolated_codex_home" codex plugin list \
    | grep -Eq '^imessage-mcp@imessage-mcp-local.*installed, enabled'

modified_skill_project="$test_root/modified-skill"
mkdir -p "$modified_skill_project"
CODEX_HOME="$isolated_codex_home" "$standalone/install" \
    --project "$modified_skill_project" --allow-plugin-overlap
echo "local edit" \
    >> "$modified_skill_project/.agents/skills/imessage-conversation-watch/SKILL.md"
CODEX_HOME="$isolated_codex_home" \
    "$standalone/uninstall" --project "$modified_skill_project"
grep -Fq "local edit" \
    "$modified_skill_project/.agents/skills/imessage-conversation-watch/SKILL.md"
test ! -d "$modified_skill_project/.codex/imessage-mcp"

compatibility_file="$test_root/incompatible-connection.json"
printf '{"socketPath":"/tmp/missing.sock","token":"test","appPID":%s,"version":"2.0.0"}\n' \
    "$$" > "$compatibility_file"
if IMESSAGE_MCP_CONNECTION_FILE="$compatibility_file" \
    "$plugin/bin/imessage-mcp" >/dev/null 2>"$test_root/incompatible.log"; then
    echo "Proxy accepted an incompatible running app version." >&2
    exit 1
fi
grep -Fq "incompatible with menu-app version 2.0.0" \
    "$test_root/incompatible.log"

stale_file="$test_root/stale-connection.json"
printf '%s\n' \
    '{"socketPath":"/tmp/missing.sock","token":"test","appPID":2147483647,"version":"1.0.0"}' \
    > "$stale_file"
if IMESSAGE_MCP_CONNECTION_FILE="$stale_file" \
    "$plugin/bin/imessage-mcp" >/dev/null 2>"$test_root/stale.log"; then
    echo "Proxy accepted a stale connection file." >&2
    exit 1
fi
grep -Fq "saved menu-app connection is stale" "$test_root/stale.log"

echo "Distribution checks passed."
