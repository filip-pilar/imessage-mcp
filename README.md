# iMessage MCP

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
open "/Users/phil/Documents/forma-code/imessage-mcp/dist/iMessage MCP.app"
```

Build the standalone proxy without rebuilding or re-signing the menu app:

```bash
./scripts/build-proxy.sh
```

Register that proxy with Codex:

```bash
codex mcp add imessage -- "/Users/phil/Documents/forma-code/imessage-mcp/dist/imessage-mcp"
```

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
| `read_attachment` | Image content or metadata for a returned attachment |
| `send_message` | Text and/or one file to a chat, phone, email, or contact |
| `react_to_latest` | One of six standard tapbacks to the latest inbound message |
| `get_send_status` | Pending/sent/delivered/failed state and available read date |

Resources:

- `imessage://events/recent` supports MCP subscriptions.
- `imessage://status` reports current broker, permission, watcher, active-client,
  and policy state.

Live events retain the latest 500 events in memory. Cursors include an opaque
app-session identity. After a restart, tools return `cursor_expired` instead of
silently waiting on a stale position; use bounded chat history to recover.

`wait_for_message` waits only while its MCP call is active and never wakes a
completed Codex task. It defaults to events arriving after the call begins,
ignores reactions and other chats, and returns `matched`, `timeout`,
`cursor_expired`, or `watcher_unavailable`.

## Codex conversation-watch skill

The project includes `.agents/skills/imessage-conversation-watch`. In a fresh
Codex task, requests such as “watch my conversation with Alex for the next
reply” automatically use the bounded wait workflow. The skill resolves exactly
one chat, snapshots a restart-aware cursor, waits for at most 55 seconds per
call, and reports timeouts or cursor gaps honestly. Watching remains read-only;
sends and tapbacks always require separate explicit authorization.

## Write policy

The menu presents three clear write modes:

- **Read Only:** clients can read but cannot send or react.
- **Ask Before Writes:** every send and tapback needs menu approval.
- **Allow Without Asking:** trusted clients can write immediately.

The Settings window can customize message and tapback confirmation separately.
Approvals show the resolved chat label, the exact preview, and an expiry
countdown; they time out closed after 120 seconds.

For the least ambiguous send:

- use a `chat_id` returned by `list_chats`, especially for groups;
- use an E.164 phone number for a new direct recipient;
- set `no_sms_fallback: true` when accidental SMS fallback is unacceptable;
- pass `expected_message_guid` to `react_to_latest` so it fails if the latest
  inbound message changed.

Activity history stores operation type, target/chat identifier, client
connections, status, and errors—not message bodies. Live-event persistence is
debounced to avoid rewriting the activity file for every burst. It is kept locally in
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
swift test
./scripts/build-app.sh
./scripts/smoke-app.sh
```

`build-app.sh` creates a universal arm64/x86_64 app, downloads the pinned imsg
release only when needed, verifies its SHA-256, generates the icon, signs the
local bundle, and runs strict code-signature verification.

`smoke-app.sh` starts the packaged native app against a fixture executable,
then verifies the authenticated broker, stdio proxy, MCP initialization, and a
tool call without touching the real Messages database or sending anything.

This project is not affiliated with or endorsed by Apple Inc. iMessage is a
trademark of Apple Inc.
