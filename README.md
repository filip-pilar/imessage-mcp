# iMessage MCP

Let trusted AI clients securely read, search, monitor, send, and react to
messages through macOS Messages.

A local MCP server and native macOS menu-bar app for Messages. It bundles
[`imsg`](https://github.com/openclaw/imsg) 0.13.3 and exposes the useful
SIP-enabled surface: local history, search, attachments, live events, sends,
delivery-state inspection, and standard tapbacks.

The app never opens a network listener. MCP clients connect through a bundled
stdio proxy to an authenticated, user-only Unix socket.

## Open and connect

Build the app:

```bash
./scripts/build-app.sh
```

Open its menu:

```bash
open "$(pwd)/dist/iMessage MCP.app"
```

Build the standalone proxy without rebuilding or re-signing the menu app:

```bash
./scripts/build-proxy.sh
```

Register that proxy with Codex:

```bash
codex mcp add imessage -- "$(pwd)/dist/imessage-mcp"
```

Run these commands from the repository root. For a persistent project-local
development setup, copy `.codex/config.example.toml` to `.codex/config.toml`
and replace its placeholder with the absolute proxy path. The personal
`config.toml` is intentionally ignored.

The standalone proxy starts the unchanged sibling menu app automatically when
an MCP client connects.
Existing MCP client processes may need to be restarted after registration.
The menu counts active proxy sessions, not clients that are merely configured.
An idle client therefore shows **Connects on demand**; an active client is
identified by name and the menu retains its most recent connection time.

## Permissions

The menu shows the current state and links to the relevant System Settings
pages.

- **Full Disk Access:** add `iMessage MCP.app`, then quit and reopen it. This
  permits read-only access to `~/Library/Messages/chat.db`.
- **Automation → Messages:** macOS normally asks once on the first send for the
  current signed build. This permits the app to ask Messages to send approved
  content.
- **Automation → System Events:** macOS can ask separately on the first
  tapback. System Events is used only for tapback UI automation.
- **Accessibility:** add the app when prompted. Required only for tapbacks,
  because `imsg react` verifies the selected reaction through Messages UI.
- **Contacts:** optional. Enables contact-name resolution.

The app is locally ad-hoc signed. Apple documents that this identity is tied to
one exact build, so rebuilding changes the code requirement used by macOS
privacy controls. After any rebuild, remove the old app entry from Accessibility
and Full Disk Access, add the newly built app, then quit and reopen it. Moving
the unchanged app does not normally change its identity.

## MCP surface

| Tool | Behavior |
| --- | --- |
| `check_setup` | Bundled imsg version plus actual database, permission, watcher, client, and policy state |
| `list_chats` | Recent or unread conversations |
| `get_chat` | Chat identity, routing, and participants |
| `get_chat_background` | Local background metadata and cache state |
| `get_messages` | Bounded history with optional attachment metadata/conversion |
| `search_messages` | Contains or exact local-history search |
| `message_statistics` | Message and optional media statistics |
| `list_scheduled_messages` | Read-only inspection of Messages Send Later rows |
| `list_local_accounts` | Accounts observed in local history |
| `lookup_handle` | Local service-history and Contacts lookup |
| `get_new_messages` | Restart-detecting cursor over the live message/reaction buffer |
| `wait_for_message` | Bounded 1–90 second wait for the next incoming message in one chat |
| `read_attachment` | Image content or metadata only from Messages attachments or the dedicated imsg conversion cache |
| `send_message` | Text and/or one file to a chat ID, canonical E.164 phone number, or email address |
| `react_to_latest` | One of six standard tapbacks when the required latest-message GUID still matches |
| `get_send_status` | Pending/sent/delivered/failed state and available read date |

Resources:

- `imessage://events/recent` supports MCP subscriptions.
- `imessage://status` reports current broker, permission, watcher, active-client,
  and policy state.

Live events retain the latest 500 events in memory. Cursors include an opaque
watcher-generation identity. After an app restart or any watcher continuity
break, tools return `cursor_expired` instead of silently waiting on a stale
position; use bounded chat history to inspect the unmonitored gap.

The proxy ignores connection descriptors whose app process no longer exists,
launches the menu app to replace them, and rejects menu apps from an
incompatible semantic major version with a clear error.

`wait_for_message` waits only while its MCP call is active and never wakes a
completed Codex task. Client cancellation or disconnect wakes the wait
immediately. It defaults to events arriving after the call begins,
ignores reactions and other chats, and returns `matched`, `timeout`,
`cursor_expired`, or `watcher_unavailable`.

## Codex conversation-watch skill

The project includes `.agents/skills/imessage-conversation-watch`. In a fresh
Codex task, requests such as “watch my conversation with Alex for the next
reply” automatically use the bounded wait workflow. The skill resolves exactly
one chat, snapshots a restart-aware cursor, waits for at most 55 seconds per
call, and reports timeouts or cursor gaps honestly. Watching remains read-only;
sends and tapbacks always require separate explicit authorization.

## Distribution options

The native menu app is installed separately in both options so rebuilding a
Codex integration never changes its macOS privacy identity.

### Standalone project scope

Keep direct MCP and skill control per project. Build both self-contained
archives without rebuilding the menu app:

```bash
./scripts/package-distributions.sh --skip-build
```

Then unpack `dist/imessage-mcp-standalone-local-private.zip` and run:

```bash
./install --project "/absolute/path/to/project"
```

Add `--mcp-only` when the project should receive the MCP without the
conversation-watch skill. Existing, different `mcp_servers.imessage`
configuration is never overwritten. The installer also refuses to create a
duplicate tool surface while the plugin is enabled. Run the packaged
`uninstall` command to remove only standalone-owned files.

### Plugin package

`dist/imessage-mcp-local-private.zip` is a ready-to-add local marketplace
containing the MCP proxy and conversation-watch skill. After unzipping, change
to the directory containing `imessage-mcp-local-private` and run:

```bash
PLUGIN_MARKETPLACE="$(pwd)/imessage-mcp-local-private"
codex plugin marketplace add "$PLUGIN_MARKETPLACE"
codex plugin add imessage-mcp@imessage-mcp-local
```

Start a fresh Codex task afterward. Exact removal commands are included in the
archive README. The plugin launcher looks for the separately installed menu
app in `/Applications` or `~/Applications`; `IMESSAGE_MCP_APP_PATH` can
identify another unchanged location.

Both archives are explicitly local/private, ad-hoc signed, and not notarized.
Do not publish or share them until stable Developer ID signing and notarization
are implemented. Do not enable both distributions in the same Codex task
except for a controlled migration test.

The project-scoped skill is canonical. Run
`./scripts/sync-distributions.sh` after editing it, and
`./scripts/sync-distributions.sh --check` in validation to prevent the plugin
copy from drifting.

## Write policy

The menu presents three clear write modes:

- **Read Only:** clients can read but cannot send or react.
- **Ask Before Writes:** every send and tapback needs menu approval.
- **Allow Without Asking:** trusted clients can write immediately.

The Settings window can customize message and tapback confirmation separately.
Approvals show the canonical target, full untruncated text, delivery service,
SMS fallback behavior, exact tapback GUID, and canonical attachment metadata.
Outbound attachment bytes are copied to a private, bounded staging file before
approval and that exact copy is used for delivery. Normal shutdown drains
accepted writes; failed or crash-interrupted cleanup is retried by a contained
startup sweep. Approvals expire closed after 120 seconds. Allow Without Asking skips the dialog but
uses the same strict intent validation and final policy, target, and attachment
checks. The menu-bar item shows the number of pending approvals. Optional local
notifications show only a generic pending count and batch subsequent count
changes without exposing message or recipient details.

The local broker rejects duplicate outstanding JSON-RPC IDs and applies bounded
per-client, broker-wide, and pending-approval limits with explicit overload
errors.

For the least ambiguous send:

- use a `chat_id` returned by `list_chats`, especially for groups;
- use an E.164 phone number for a new direct recipient;
- set `no_sms_fallback: true` when accidental SMS fallback is unacceptable;
- provide the required `expected_message_guid` to `react_to_latest`; the tool
  rechecks it immediately before acting and fails if the target changed.

Activity history stores only stable redacted operation summaries. Recipients,
message bodies, attachment names, client-provided details, and raw errors are
not persisted; detailed errors remain transient in the tool response. Legacy
activity is rewritten or purged on load. Live-event persistence is debounced to
avoid rewriting the activity file for every burst. It is kept locally in
`~/Library/Application Support/iMessage MCP/`.

## Honest macOS and imsg limits

- Programmatically marking a chat read (which can generate a read receipt),
  typing indicators, exact-message replies, edit/unsend, stickers, polls,
  arbitrary emoji tapbacks, and group mutations use imsg's private IMCore
  bridge. That bridge requires disabling SIP and remains unreliable on current
  macOS, so this app deliberately does not bundle or expose it.
- `react_to_latest` can only target the most recent inbound message. It may
  foreground Messages and needs Accessibility.
- Custom emoji and reaction removal can be observed but not sent through the
  public automation surface.
- Send Later rows can be read, but imsg has no SIP-safe scheduled-send writer.
- Available outgoing read timestamps and delivery state are observations from
  `chat.db`; the tool does not force the recipient to send read receipts.
- SMS requires Text Message Forwarding from an iPhone. AppleScript cannot force
  a particular originating phone number.
- Receive-side CAF/GIF conversion is optional and needs `ffmpeg` on `PATH`.
- A connected MCP client can request local message contents. Only register
  clients you trust; read tools do not show per-call approval prompts.

## Real-world test checklist

1. Open the app, grant Full Disk Access, quit/reopen, and confirm **Messages
   database — Ready**.
2. Call `check_setup`, `list_chats`, then `get_messages` on a harmless chat.
3. Confirm the menu identifies the active MCP client, then returns to a
   last-connected state when the client exits.
4. Send a unique text to yourself; approve the contact-labelled menu card,
   accept the one-time Messages Automation prompt if needed, and verify receipt.
5. Send a small image to yourself; verify it arrives, then read it back via
   `get_messages(attachments: true)` and `read_attachment`.
6. Receive a fresh message, call `react_to_latest` with its GUID, grant
   Accessibility if asked, approve, and verify the tapback.
7. Leave the app open, receive another message, and verify
   `get_new_messages` or the subscribed events resource updates.
8. Call `get_send_status` with the outgoing GUID and inspect the state.

## Development and verification

```bash
./scripts/check.sh
```

`check.sh` verifies shell syntax, portable configuration, synchronized versions
and skill copies, then runs the Swift test suite. Changes to packaging or the
native app need the additional focused checks below:

```bash
./scripts/build-app.sh
./scripts/smoke-app.sh
./scripts/test-distributions.sh
```

`build-app.sh` creates a universal arm64/x86_64 app, downloads the pinned imsg
release only when needed, verifies its SHA-256, generates the icon, signs the
local bundle, and runs strict code-signature verification.

`smoke-app.sh` starts the packaged native app against a fixture executable,
then verifies the authenticated broker, stdio proxy, MCP initialization, and a
tool call without touching the real Messages database or sending anything.

This project is not affiliated with or endorsed by Apple Inc. iMessage is a
trademark of Apple Inc.
