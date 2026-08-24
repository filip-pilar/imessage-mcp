import Foundation

extension ToolService {
    public static let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "check_setup",
            title: "Check iMessage Setup",
            description: "Check the bundled imsg version and local Messages integration status.",
            inputSchema: emptySchema(),
            readOnly: true
        ),
        ToolDefinition(
            name: "list_chats",
            title: "List Chats",
            description: "List recent iMessage and SMS conversations, including names, participants and unread counts.",
            inputSchema: objectSchema([
                "limit": integer("Maximum chats to return.", minimum: 1, maximum: 200),
                "unread_only": boolean("Return only chats with unread inbound messages."),
            ]),
            readOnly: true
        ),
        ToolDefinition(
            name: "get_chat",
            title: "Get Chat",
            description: "Get identity, service and participant information for one chat.",
            inputSchema: objectSchema(
                [
                    "chat_id": integer("Chat row ID from list_chats.", minimum: 1)
                ], required: ["chat_id"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "get_chat_background",
            title: "Get Chat Background",
            description: "Inspect locally recorded Messages background metadata and cached asset state for one chat.",
            inputSchema: objectSchema(
                [
                    "chat_id": integer("Chat row ID from list_chats.", minimum: 1)
                ], required: ["chat_id"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "get_messages",
            title: "Get Messages",
            description: "Read messages from one chat with optional date bounds and attachment metadata.",
            inputSchema: objectSchema(
                [
                    "chat_id": integer("Chat row ID from list_chats.", minimum: 1),
                    "limit": integer("Maximum messages to return.", minimum: 1, maximum: 500),
                    "start": string("Inclusive ISO 8601 start date."),
                    "end": string("Exclusive ISO 8601 end date."),
                    "attachments": boolean("Include attachment metadata."),
                    "convert_attachments": boolean("Create model-compatible CAF/GIF cache variants."),
                ], required: ["chat_id"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "search_messages",
            title: "Search Messages",
            description: "Search local Messages history by text.",
            inputSchema: objectSchema(
                [
                    "query": string("Text to search for.", minLength: 1),
                    "match": enumString("Match behavior.", values: ["contains", "exact"]),
                    "limit": integer("Maximum results.", minimum: 1, maximum: 500),
                ], required: ["query"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "message_statistics",
            title: "Message Statistics",
            description: "Calculate message and optional media statistics globally or for one chat.",
            inputSchema: objectSchema([
                "chat_id": integer("Optional chat row ID.", minimum: 1),
                "time_zone": string("Optional IANA time zone."),
                "include_media": boolean("Include attachment totals and sizes."),
            ]),
            readOnly: true
        ),
        ToolDefinition(
            name: "list_scheduled_messages",
            title: "List Scheduled Messages",
            description: "List future Send Later messages recorded by Messages.",
            inputSchema: objectSchema([
                "limit": integer("Maximum scheduled messages.", minimum: 1, maximum: 200)
            ]),
            readOnly: true
        ),
        ToolDefinition(
            name: "list_local_accounts",
            title: "List Local iMessage Accounts",
            description:
                "List iMessage account logins observed in local Messages history. This is historical, not a live signed-in account check.",
            inputSchema: emptySchema(),
            readOnly: true
        ),
        ToolDefinition(
            name: "lookup_handle",
            title: "Look Up Message Handle",
            description:
                "Infer a phone number or email's preferred service from local history and resolve its local Contacts name when available.",
            inputSchema: objectSchema(
                [
                    "address": string("Phone number or email address.", minLength: 1)
                ], required: ["address"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "get_new_messages",
            title: "Get New Messages",
            description:
                "Get buffered live message and reaction events after an opaque watcher cursor. An expired cursor is reported explicitly after app restart, watcher restart, or any continuity break.",
            inputSchema: objectSchema([
                "cursor": string("Opaque cursor returned by this tool. Omit initially."),
                "limit": integer("Maximum events.", minimum: 1, maximum: 200),
            ]),
            readOnly: true
        ),
        ToolDefinition(
            name: "wait_for_message",
            title: "Wait for Message",
            description:
                "Wait a bounded time for the next incoming non-reaction message in one chat. This does not keep a completed Codex task alive.",
            inputSchema: objectSchema(
                [
                    "chat_id": integer("Chat row ID from list_chats.", minimum: 1),
                    "cursor": string(
                        "Opaque cursor returned by get_new_messages or wait_for_message. Omit to wait only for future events."
                    ),
                    "timeout_seconds": integer("Maximum wait time.", minimum: 1, maximum: 90),
                ], required: ["chat_id"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "read_attachment",
            title: "Read Attachment",
            description:
                "Read an attachment returned by get_messages. Images are returned directly; other files return metadata.",
            inputSchema: objectSchema(
                [
                    "path": string("Absolute attachment or converted-cache path.", minLength: 1)
                ], required: ["path"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "send_message",
            title: "Send Message",
            description:
                "Send text and/or one attachment through Messages.app to an existing chat, canonical E.164 phone number, or email address.",
            inputSchema: objectSchema(
                [
                    "chat_id": integer("Existing chat row ID.", minimum: 1),
                    "to": string("Canonical E.164 phone number or email address.", minLength: 1),
                    "text": string("Message body."),
                    "file": string("Absolute path to one attachment."),
                    "service": enumString("Delivery service.", values: ["auto", "imessage", "sms"]),
                    "no_sms_fallback": boolean("Prevent fallback from iMessage to SMS."),
                ], oneOfRequired: [["chat_id"], ["to"]]),
            readOnly: false,
            openWorld: true
        ),
        ToolDefinition(
            name: "react_to_latest",
            title: "React to Latest Message",
            description:
                "Send a standard tapback to the most recent incoming message in a chat. This uses Messages UI automation and may bring Messages to the foreground.",
            inputSchema: objectSchema(
                [
                    "chat_id": integer("Existing chat row ID.", minimum: 1),
                    "reaction": enumString(
                        "Standard tapback.",
                        values: ["love", "like", "dislike", "laugh", "emphasis", "question"]
                    ),
                    "expected_message_guid": string(
                        "Exact GUID of the expected most recent incoming message.",
                        minLength: 1
                    ),
                ], required: ["chat_id", "reaction", "expected_message_guid"]),
            readOnly: false,
            openWorld: true
        ),
        ToolDefinition(
            name: "get_send_status",
            title: "Get Send Status",
            description:
                "Inspect pending, sent, delivered or failed state and available read timestamp for an outgoing message GUID.",
            inputSchema: objectSchema(
                [
                    "guid": string("Outgoing message GUID.", minLength: 1)
                ], required: ["guid"]),
            readOnly: true
        ),
    ]
}

private func emptySchema() -> [String: Any] {
    [
        "type": "object",
        "properties": [String: Any](),
        "additionalProperties": false,
    ]
}

private func objectSchema(
    _ properties: [String: Any],
    required: [String] = [],
    oneOfRequired: [[String]] = []
) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]
    if !required.isEmpty { schema["required"] = required }
    if !oneOfRequired.isEmpty {
        schema["oneOf"] = oneOfRequired.map { ["required": $0] }
    }
    return schema
}

private func string(_ description: String, minLength: Int? = nil) -> [String: Any] {
    var value: [String: Any] = ["type": "string", "description": description]
    if let minLength { value["minLength"] = minLength }
    return value
}

private func enumString(_ description: String, values: [String]) -> [String: Any] {
    ["type": "string", "description": description, "enum": values]
}

private func integer(
    _ description: String,
    minimum: Int? = nil,
    maximum: Int? = nil
) -> [String: Any] {
    var value: [String: Any] = ["type": "integer", "description": description]
    if let minimum { value["minimum"] = minimum }
    if let maximum { value["maximum"] = maximum }
    return value
}

private func boolean(_ description: String) -> [String: Any] {
    ["type": "boolean", "description": description]
}
