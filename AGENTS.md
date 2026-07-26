# Repository guide

## Project

iMessage MCP is a Swift 6 package targeting macOS 14 and later. It contains:

- `MessageMCPKit`: broker, MCP protocol, tools, stores, and the `imsg` adapter.
- `iMessageMCP`: native menu-bar app and approval UI.
- `imessage-mcp`: stdio-to-Unix-socket proxy.
- `.agents/skills/imessage-conversation-watch`: canonical Codex skill.
- `distribution/`: standalone and local-plugin packaging sources.

Read `ARCHITECTURE.md` before changing runtime boundaries and `SECURITY.md`
before changing tools, permissions, persistence, attachments, or distribution.

## Security invariants

Preserve these unless the task explicitly changes the documented security model:

- Do not add a TCP listener, telemetry, or remote message storage.
- Never evaluate tool input through a shell. Pass arguments directly to `Process`.
- Do not expose functionality that requires disabling SIP.
- Sends and reactions must respect write settings and fail closed on denial or timeout.
- Do not persist message bodies, attachment contents, addresses, or broker tokens in logs.
- Keep attachment path, regular-file, and size validation.
- Tests and smoke checks must not access the real Messages database or send messages.

## Sources of truth

- Edit `.agents/skills/imessage-conversation-watch` as the canonical skill.
- Do not directly edit its copy under
  `distribution/local-private-marketplace/plugins/imessage-mcp/skills`.
- After skill changes, run `./scripts/sync-distributions.sh`.
- Treat `dist/`, `.build/`, and `Vendor/imsg/` as generated artifacts.
- Do not hand-edit packaged archives or generated app bundles.
- Keep server, app, plugin, test, and bundled-`imsg` versions synchronized.

## Change conventions

- Add or update tests with behavioral changes.
- New or changed MCP tools require a schema and annotations, server-side
  validation, implementation and error behavior, focused tests, and a README
  tool-table update.
- Preserve restart-aware event cursors and bounded waits.
- Preserve semantic-major compatibility between the proxy and menu app.
- Keep shell scripts POSIX-compatible, quoted, and under `set -eu`.
- Use `Tests/Fixtures/fake-imsg` for process and integration behavior.

## Verification

For ordinary changes:

```sh
./scripts/check.sh
```

Unix-socket tests can fail with `bind: Operation not permitted` inside a
restricted agent sandbox. Rerun them with approved host permissions; do not
change product code to accommodate that sandbox error.

For packaged-app changes:

```sh
./scripts/build-app.sh
./scripts/smoke-app.sh
```

`build-app.sh` downloads the pinned `imsg` artifact when absent and creates a
new ad-hoc-signed app identity. Do not run it unnecessarily because rebuilding
can invalidate existing macOS privacy grants.

For installer, plugin, launcher, skill, or packaging changes:

```sh
./scripts/test-distributions.sh
```

State which checks were run and disclose any checks that were skipped.
