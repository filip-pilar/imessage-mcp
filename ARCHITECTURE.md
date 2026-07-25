# Architecture

## Shape

```text
MCP client
    │ newline-delimited JSON-RPC over stdio
    ▼
bundled imessage-mcp proxy
    │ token handshake + JSON-RPC
    ▼
mode-0600 Unix socket
    │
native menu-bar app
    ├── MCP processor and tool policy
    ├── approvals, activity, settings, and live-event buffer
    └── pinned bundled imsg process adapter
            ├── read-only chat.db queries and watch
            └── public Messages/AppleScript send + UI tapback
```

The menu app is the single persistent broker. This makes policy and approvals
consistent across concurrent MCP clients and allows the live watcher to survive
individual client restarts. The stdio proxy keeps compatibility with ordinary
local MCP clients and auto-launches the app.

The broker tracks authenticated sessions by client-provided MCP name and
connection time. The UI distinguishes active sessions from configured clients
that connect only on demand and retains the latest connection time for context.

## Protocol

The MCP processor implements JSON-RPC lifecycle, ping, tools, resources,
resource subscriptions, and logging level negotiation. It advertises MCP
`2025-11-25` and accepts `2025-06-18` and `2025-03-26` clients.

Each app launch creates a random 256-bit token. The socket path includes the
current uid and is mode `0600`; the connection descriptor containing the token
is stored mode `0600` under the app-support directory. A client must complete
the token handshake before MCP frames are processed.

## imsg boundary

All CLI arguments are passed to `Process` as an argument array; no tool input is
evaluated by a shell. Bounded one-shot processes isolate failures and enforce
timeouts. The watcher is supervised and restarted with exponential backoff.

The advanced bridge helper is removed during vendoring. This guarantees the
shipped app stays on the SIP-enabled surface even though upstream imsg also
contains private IMCore commands.

## State and privacy

- Settings and operation metadata persist locally as mode-`0600` JSON.
- Runtime readiness is lock-protected and shared by the menu, `check_setup`,
  and `imessage://status`, so database, permission, watcher, and client state
  describe the running app rather than configuration alone.
- Live message/reaction payloads remain in a bounded in-memory buffer.
- Live cursors combine an app-session identity with an event position, so a
  restart is reported as cursor expiration rather than mistaken for inactivity.
- Bounded message waits use an in-process condition and never create background
  or autonomous work after the MCP call returns.
- Message bodies are not written to the activity log.
- High-frequency live-event activity persistence is debounced.
- Read attachments are restricted to Messages and imsg cache locations and
  capped at 20 MB for MCP image content.
- Outbound attachments must be regular files and default to a 100 MB cap.
- Sends and reactions are separately confirmable and fail closed on timeout.

Environment overrides (`IMSG_PATH`, `IMESSAGE_MCP_HOME`,
`IMESSAGE_MCP_SOCKET_PATH`, and `IMESSAGE_MCP_CONNECTION_FILE`) exist for
isolated integration testing. Normal packaged operation does not set them.
