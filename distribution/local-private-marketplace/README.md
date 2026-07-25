# iMessage MCP local private marketplace

This package is for local testing only. The menu app and proxy are ad-hoc
signed and are not notarized. Do not publish or share this package until stable
Developer ID signing and notarization are implemented.

The native **iMessage MCP.app** remains a separate installation. Keep the
unchanged app in `/Applications`, `~/Applications`, or set
`IMESSAGE_MCP_APP_PATH`.

## Install

Unzip the archive, change to the directory containing
`imessage-mcp-local-private`, then run exactly:

```bash
PLUGIN_MARKETPLACE="$(pwd)/imessage-mcp-local-private"
codex plugin marketplace add "$PLUGIN_MARKETPLACE"
codex plugin add imessage-mcp@imessage-mcp-local
```

Start a fresh Codex task after installation.

Do not use this plugin in a project that also defines
`[mcp_servers.imessage]` in `.codex/config.toml`. Remove the standalone
project installation first; running both creates duplicate iMessage tool
surfaces.

## Uninstall

```bash
codex plugin remove imessage-mcp@imessage-mcp-local
codex plugin marketplace remove imessage-mcp-local
```

Removing the plugin does not alter any project-scoped standalone installation.
