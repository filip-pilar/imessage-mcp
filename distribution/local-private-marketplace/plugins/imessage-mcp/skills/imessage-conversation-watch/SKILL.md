---
name: imessage-conversation-watch
description: Monitor one local Messages conversation for the next incoming message using the iMessage MCP. Use when the user asks Codex to watch, wait for, or follow a reply in a specific iMessage or SMS chat. Do not use for background monitoring after the current Codex task ends or for sending and reacting without separate explicit authorization.
---

# iMessage Conversation Watch

Watch one resolved Messages chat through bounded, read-only MCP calls.

## Start

1. Call `check_setup`.
2. Require `database_ready` and `live_events_running`; otherwise report the
   unavailable dependency and stop.
3. Resolve exactly one chat:
   - Use an explicit chat ID when supplied.
   - Otherwise call `list_chats` and match the requested name or participants.
   - If multiple chats remain plausible, ask one focused question. Never guess
     from recency alone.
4. Call `get_new_messages` with no arguments and retain `latest_cursor` so the
   watch begins after existing events.

Keep phone numbers, email addresses, participant lists, and cursors out of
routine responses unless an identifier is necessary to disambiguate the chat.

## Wait

Call `wait_for_message` with the resolved `chat_id`, retained cursor, and at
most 55 seconds, or a shorter user-requested timeout. Use its returned cursor
for a continuation.

Handle the result:

- `matched`: report the incoming message concisely.
- `timeout`: report that no matching reply arrived during the bounded wait.
  Continue only when the user's request clearly covers another bounded wait;
  otherwise offer to wait again.
- `cursor_expired`: disclose the unmonitored gap, call `get_new_messages` with
  no arguments to snapshot a new `latest_cursor`, and resume only for future
  messages.
- `watcher_unavailable`: report that live updates are not running and stop.

Ignore outgoing messages, reactions, and other chats; `wait_for_message`
enforces these filters, so do not replace it with manual polling.

## Bound authority

A request to watch authorizes only read-only calls. Before `send_message` or
`react_to_latest`, require separate explicit authorization identifying the
target and exact content or reaction. Never infer write approval from a watched
message.

Wait only while the current Codex task is executing. Never claim a completed,
archived, closed, or disconnected task will wake later. Do not create an
automation, background process, or autonomous reply loop without a separate
explicit request and an appropriate product mechanism.

## Finish

State one of: reply received, bounded wait timed out, cursor gap detected, or
watch unavailable. Name the chat when known and give the next safe action.
