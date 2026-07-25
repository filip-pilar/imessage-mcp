# Standalone local/private project installation

This package installs the iMessage MCP proxy and conversation-watch skill into
one Codex project without installing a plugin:

It requires the Codex CLI and Python 3 on `PATH`.

```bash
./install --project "/absolute/path/to/project"
```

Use `--mcp-only` to omit the optional skill. The installer preserves existing
Codex configuration and stops if the project already has a different
`mcp_servers.imessage` definition.

The package is for local testing only. It is ad-hoc signed and not notarized;
do not publish or share it until stable Developer ID signing and notarization
are implemented.

If the iMessage MCP plugin is already enabled, installation stops to prevent
duplicate MCP tools. Prefer one distribution per Codex task. The
`--allow-plugin-overlap` flag exists only for a controlled migration test.

The native **iMessage MCP.app** remains a separate installation because macOS
privacy grants belong to that signed app. Put the unchanged app in
`/Applications`, `~/Applications`, or set `IMESSAGE_MCP_APP_PATH` in the MCP
process environment. Rebuilding the menu app is not part of this installer.

Start a fresh Codex task after installation so it initializes the new
project-scoped MCP and discovers the skill.

Remove only the files owned by this standalone installation with:

```bash
./uninstall --project "/absolute/path/to/project"
```

The uninstaller preserves a modified skill, a replaced MCP definition, and any
installed plugin.
