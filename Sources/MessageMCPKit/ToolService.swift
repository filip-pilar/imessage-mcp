import Foundation
import UniformTypeIdentifiers

public struct ToolDefinition: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: [String: AnySendable]
    public let annotations: [String: AnySendable]

    public init(
        name: String,
        title: String,
        description: String,
        inputSchema: [String: Any],
        readOnly: Bool,
        destructive: Bool = false,
        idempotent: Bool = false,
        openWorld: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema.mapValues(AnySendable.init)
        self.annotations = [
            "title": AnySendable(title),
            "readOnlyHint": AnySendable(readOnly),
            "destructiveHint": AnySendable(destructive),
            "idempotentHint": AnySendable(idempotent),
            "openWorldHint": AnySendable(openWorld),
        ]
    }

    public var jsonObject: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema.mapValues(\.value),
            "annotations": annotations.mapValues(\.value),
        ]
    }
}

/// Safely carries JSON-compatible values across Sendable boundaries.
public struct AnySendable: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
}

public struct ToolCallResult: Sendable {
    public let content: [AnySendable]
    public let structuredContent: AnySendable?
    public let isError: Bool

    public init(content: [[String: Any]], structuredContent: Any? = nil, isError: Bool = false) {
        self.content = content.map(AnySendable.init)
        self.structuredContent = structuredContent.map(AnySendable.init)
        self.isError = isError
    }

    public static func text(_ text: String, structured: Any? = nil) -> ToolCallResult {
        ToolCallResult(content: [["type": "text", "text": text]], structuredContent: structured)
    }

    public static func error(_ text: String) -> ToolCallResult {
        ToolCallResult(content: [["type": "text", "text": text]], isError: true)
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "content": content.map(\.value),
            "isError": isError,
        ]
        if let structuredContent {
            object["structuredContent"] = structuredContent.value
        }
        return object
    }
}

public enum ToolServiceError: LocalizedError {
    case invalid(String)
    case disabled(String)
    case denied

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .disabled(let message):
            return message
        case .denied:
            return "The action was not approved in the iMessage MCP menu."
        }
    }
}

public final class ToolService: @unchecked Sendable {
    public let runner: IMsgRunning
    public let settings: SettingsStore
    public let activity: ActivityStore
    public let events: EventStore
    public let approvals: ApprovalProviding
    private let statusProvider: @Sendable () -> [String: Any]

    public init(
        runner: IMsgRunning,
        settings: SettingsStore,
        activity: ActivityStore,
        events: EventStore,
        approvals: ApprovalProviding,
        statusProvider: @escaping @Sendable () -> [String: Any] = { [:] }
    ) {
        self.runner = runner
        self.settings = settings
        self.activity = activity
        self.events = events
        self.approvals = approvals
        self.statusProvider = statusProvider
    }

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
            inputSchema: objectSchema([
                "chat_id": integer("Chat row ID from list_chats.", minimum: 1),
            ], required: ["chat_id"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "get_chat_background",
            title: "Get Chat Background",
            description: "Inspect locally recorded Messages background metadata and cached asset state for one chat.",
            inputSchema: objectSchema([
                "chat_id": integer("Chat row ID from list_chats.", minimum: 1),
            ], required: ["chat_id"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "get_messages",
            title: "Get Messages",
            description: "Read messages from one chat with optional date bounds and attachment metadata.",
            inputSchema: objectSchema([
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
            inputSchema: objectSchema([
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
                "limit": integer("Maximum scheduled messages.", minimum: 1, maximum: 200),
            ]),
            readOnly: true
        ),
        ToolDefinition(
            name: "list_local_accounts",
            title: "List Local iMessage Accounts",
            description: "List iMessage account logins observed in local Messages history. This is historical, not a live signed-in account check.",
            inputSchema: emptySchema(),
            readOnly: true
        ),
        ToolDefinition(
            name: "lookup_handle",
            title: "Look Up Message Handle",
            description: "Infer a phone number or email's preferred service from local history and resolve its local Contacts name when available.",
            inputSchema: objectSchema([
                "address": string("Phone number or email address.", minLength: 1),
            ], required: ["address"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "get_new_messages",
            title: "Get New Messages",
            description: "Get buffered live message and reaction events after an opaque app-session cursor. An expired cursor is reported explicitly after an app restart.",
            inputSchema: objectSchema([
                "cursor": string("Opaque cursor returned by this tool. Omit initially."),
                "limit": integer("Maximum events.", minimum: 1, maximum: 200),
            ]),
            readOnly: true
        ),
        ToolDefinition(
            name: "wait_for_message",
            title: "Wait for Message",
            description: "Wait a bounded time for the next incoming non-reaction message in one chat. This does not keep a completed Codex task alive.",
            inputSchema: objectSchema([
                "chat_id": integer("Chat row ID from list_chats.", minimum: 1),
                "cursor": string("Opaque cursor returned by get_new_messages or wait_for_message. Omit to wait only for future events."),
                "timeout_seconds": integer("Maximum wait time.", minimum: 1, maximum: 90),
            ], required: ["chat_id"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "read_attachment",
            title: "Read Attachment",
            description: "Read an attachment returned by get_messages. Images are returned directly; other files return metadata.",
            inputSchema: objectSchema([
                "path": string("Absolute attachment or converted-cache path.", minLength: 1),
            ], required: ["path"]),
            readOnly: true
        ),
        ToolDefinition(
            name: "send_message",
            title: "Send Message",
            description: "Send text and/or one attachment through Messages.app to an existing chat or a phone number, email or contact name.",
            inputSchema: objectSchema([
                "chat_id": integer("Existing chat row ID.", minimum: 1),
                "to": string("Phone number, email or contact name.", minLength: 1),
                "text": string("Message body."),
                "file": string("Absolute path to one attachment."),
                "service": enumString("Delivery service.", values: ["auto", "imessage", "sms"]),
                "region": string("Default region used to normalize local phone numbers."),
                "no_sms_fallback": boolean("Prevent fallback from iMessage to SMS."),
            ], oneOfRequired: [["chat_id"], ["to"]]),
            readOnly: false,
            openWorld: true
        ),
        ToolDefinition(
            name: "react_to_latest",
            title: "React to Latest Message",
            description: "Send a standard tapback to the most recent incoming message in a chat. This uses Messages UI automation and may bring Messages to the foreground.",
            inputSchema: objectSchema([
                "chat_id": integer("Existing chat row ID.", minimum: 1),
                "reaction": enumString(
                    "Standard tapback.",
                    values: ["love", "like", "dislike", "laugh", "emphasis", "question"]
                ),
                "expected_message_guid": string("Optional GUID of the expected most recent incoming message."),
            ], required: ["chat_id", "reaction"]),
            readOnly: false,
            openWorld: true
        ),
        ToolDefinition(
            name: "get_send_status",
            title: "Get Send Status",
            description: "Inspect pending, sent, delivered or failed state and available read timestamp for an outgoing message GUID.",
            inputSchema: objectSchema([
                "guid": string("Outgoing message GUID.", minLength: 1),
            ], required: ["guid"]),
            readOnly: true
        ),
    ]

    public func call(name: String, arguments: [String: Any]) -> ToolCallResult {
        do {
            switch name {
            case "check_setup": return try checkSetup()
            case "list_chats": return try listChats(arguments)
            case "get_chat": return try getChat(arguments)
            case "get_chat_background": return try getChatBackground(arguments)
            case "get_messages": return try getMessages(arguments)
            case "search_messages": return try searchMessages(arguments)
            case "message_statistics": return try statistics(arguments)
            case "list_scheduled_messages": return try scheduled(arguments)
            case "list_local_accounts": return try localAccounts()
            case "lookup_handle": return try lookupHandle(arguments)
            case "get_new_messages": return try newMessages(arguments)
            case "wait_for_message": return try waitForMessage(arguments)
            case "read_attachment": return try readAttachment(arguments)
            case "send_message": return try sendMessage(arguments)
            case "react_to_latest": return try react(arguments)
            case "get_send_status": return try sendStatus(arguments)
            default:
                return .error("Unknown tool: \(name)")
            }
        } catch {
            activity.append(ActivityEntry(
                kind: .error,
                title: name,
                detail: error.localizedDescription,
                succeeded: false
            ))
            return .error(error.localizedDescription)
        }
    }

    private func checkSetup() throws -> ToolCallResult {
        let version = try runner.run(arguments: ["--version"], timeout: 10)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusOutput = try runner.run(arguments: ["status", "--json"], timeout: 15)
        let status = statusOutput.jsonValue
        var result = statusProvider()
        result["imsg_version"] = version
        result["imsg_status"] = status
        result["writes_enabled"] = settings.value.writesEnabled
        result["live_events_enabled"] = settings.value.liveEventsEnabled
        result["sip_enabled_mode"] = true
        result["advanced_imcore_tools_exposed"] = false
        activity.append(ActivityEntry(kind: .diagnostic, title: "Setup checked", detail: "imsg \(version)"))
        return jsonResult(result)
    }

    private func listChats(_ args: [String: Any]) throws -> ToolCallResult {
        var command = ["chats", "--limit", "\(try int(args, "limit", default: 20, range: 1...200))"]
        if bool(args, "unread_only", default: false) { command.append("--unread-only") }
        let result = try runJSON(command)
        logRead("Listed chats", detail: bool(args, "unread_only", default: false) ? "Unread only" : "Recent")
        return jsonResult(result)
    }

    private func getChat(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        let result = try runJSON(["group", "--chat-id", "\(chatID)"])
        logRead("Read chat", detail: "Chat \(chatID)")
        return jsonResult(result)
    }

    private func getChatBackground(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        let result = try runJSON(["chat-background", "status", "--chat-id", "\(chatID)"])
        logRead("Read chat background", detail: "Chat \(chatID)")
        return jsonResult(result)
    }

    private func getMessages(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        var command = [
            "history", "--chat-id", "\(chatID)",
            "--limit", "\(try int(args, "limit", default: 50, range: 1...500))",
        ]
        if let start = optionalString(args, "start") { command += ["--start", start] }
        if let end = optionalString(args, "end") { command += ["--end", end] }
        let wantsConversion = bool(args, "convert_attachments", default: false)
        if bool(args, "attachments", default: false) || wantsConversion {
            command.append("--attachments")
        }
        if wantsConversion {
            command.append("--convert-attachments")
        }
        let result = try runJSON(command)
        logRead("Read messages", detail: "Chat \(chatID)")
        return jsonResult(result)
    }

    private func searchMessages(_ args: [String: Any]) throws -> ToolCallResult {
        let query = try requiredString(args, "query")
        let match = try enumValue(args, "match", default: "contains", allowed: ["contains", "exact"])
        let limit = try int(args, "limit", default: 50, range: 1...500)
        let result = try runJSON([
            "search", "--query", query, "--match", match, "--limit", "\(limit)",
        ])
        logRead("Searched messages", detail: "\(resultCount(result)) results")
        return jsonResult(result)
    }

    private func statistics(_ args: [String: Any]) throws -> ToolCallResult {
        var params: [String: Any] = [
            "include_media": bool(args, "include_media", default: false)
        ]
        if let chatID = optionalInt64(args, "chat_id") { params["chat_id"] = chatID }
        if let zone = optionalString(args, "time_zone") { params["time_zone"] = zone }
        let result = try runner.rpc(method: "messages.stats", params: params, timeout: 30)
        logRead("Calculated statistics", detail: optionalInt64(args, "chat_id").map { "Chat \($0)" } ?? "All chats")
        return jsonResult(result)
    }

    private func scheduled(_ args: [String: Any]) throws -> ToolCallResult {
        let limit = try int(args, "limit", default: 50, range: 1...200)
        let result = try runJSON(["scheduled", "list", "--limit", "\(limit)"])
        logRead("Listed scheduled messages", detail: "\(resultCount(result)) results")
        return jsonResult(result)
    }

    private func localAccounts() throws -> ToolCallResult {
        let result = try runJSON(["account", "--local"])
        logRead("Listed local accounts", detail: "Historical Messages accounts")
        return jsonResult(result)
    }

    private func lookupHandle(_ args: [String: Any]) throws -> ToolCallResult {
        let address = try requiredString(args, "address")
        let service = try runJSON(["whois", "--address", address, "--local"])
        let contact = try runJSON(["nickname", "--address", address, "--local"])
        let result: [String: Any] = [
            "address": address,
            "service_history": service,
            "local_contact": contact,
            "note": "Service is inferred from local history; the name is from this Mac's Contacts, not a live iMessage lookup.",
        ]
        logRead("Looked up handle", detail: address)
        return jsonResult(result)
    }

    private func newMessages(_ args: [String: Any]) throws -> ToolCallResult {
        let cursor = optionalString(args, "cursor")
        let limit = try int(args, "limit", default: 50, range: 1...200)
        let batch = try events.batch(after: cursor, limit: limit)
        let decoded: [Any] = batch.events.compactMap {
            guard let data = $0.payload.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        let result: [String: Any] = [
            "status": batch.cursorExpired ? "cursor_expired" : "ok",
            "events": decoded,
            "cursor": batch.cursor.rawValue,
            "latest_cursor": batch.latestCursor.rawValue,
            "cursor_expired": batch.cursorExpired,
        ]
        return jsonResult(result)
    }

    private func waitForMessage(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        let timeout = try int(args, "timeout_seconds", default: 60, range: 1...90)
        let status = statusProvider()
        guard status["live_events_running"] as? Bool == true else {
            let cursor = events.latestCursor.rawValue
            return jsonResult([
                "status": "watcher_unavailable",
                "event": NSNull(),
                "cursor": cursor,
                "latest_cursor": cursor,
            ])
        }

        var cursor = optionalString(args, "cursor") ?? events.latestCursor.rawValue
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                let latest = events.latestCursor.rawValue
                logRead("Waited for message", detail: "Chat \(chatID) · timeout")
                return jsonResult([
                    "status": "timeout",
                    "event": NSNull(),
                    "cursor": cursor,
                    "latest_cursor": latest,
                ])
            }

            switch try events.waitForEvents(after: cursor, timeout: remaining) {
            case .cursorExpired(let latest):
                return jsonResult([
                    "status": "cursor_expired",
                    "event": NSNull(),
                    "cursor": latest.rawValue,
                    "latest_cursor": latest.rawValue,
                ])

            case .timedOut(let latest):
                logRead("Waited for message", detail: "Chat \(chatID) · timeout")
                return jsonResult([
                    "status": "timeout",
                    "event": NSNull(),
                    "cursor": latest.rawValue,
                    "latest_cursor": latest.rawValue,
                ])

            case .events(let batch):
                if let match = batch.events.first(where: {
                    isIncomingMessageEvent($0, chatID: chatID)
                }), let value = decodeLiveEvent(match) {
                    cursor = LiveEventCursor(
                        sessionID: batch.cursor.sessionID,
                        position: match.id
                    ).rawValue
                    logRead("Waited for message", detail: "Chat \(chatID) · matched")
                    return jsonResult([
                        "status": "matched",
                        "event": value,
                        "cursor": cursor,
                        "latest_cursor": batch.latestCursor.rawValue,
                    ])
                }
                cursor = batch.cursor.rawValue
            }
        }
    }

    private func decodeLiveEvent(_ event: LiveEvent) -> Any? {
        guard let data = event.payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func isIncomingMessageEvent(_ event: LiveEvent, chatID: Int64) -> Bool {
        guard let object = decodeLiveEvent(event) as? [String: Any] else { return false }
        let eventChatID = (object["chat_id"] as? NSNumber)?.int64Value
            ?? (object["chat_id"] as? String).flatMap(Int64.init)
        guard eventChatID == chatID else { return false }
        if object["is_reaction"] as? Bool == true { return false }
        if let type = object["type"] as? String, type.lowercased().contains("reaction") {
            return false
        }
        if object["is_from_me"] as? Bool == true { return false }
        return true
    }

    private func readAttachment(_ args: [String: Any]) throws -> ToolCallResult {
        let rawPath = try requiredString(args, "path")
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Messages/Attachments/")
                || url.path.hasPrefix(AppPaths.applicationSupport.path + "/")
                || url.path.hasPrefix(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path + "/")
        else {
            throw ToolServiceError.invalid("Only Messages attachments and imsg-generated cache files can be read.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true else {
            throw ToolServiceError.invalid("Attachment is not a regular file.")
        }
        let size = values.fileSize ?? 0
        guard size <= 20 * 1_024 * 1_024 else {
            throw ToolServiceError.invalid("Attachment is larger than the 20 MB MCP read limit.")
        }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            logRead("Read attachment", detail: "\(url.lastPathComponent) · \(size) bytes")
            return ToolCallResult(
                content: [
                    ["type": "image", "data": data.base64EncodedString(), "mimeType": type.preferredMIMEType ?? "image/png"],
                    ["type": "text", "text": "\(url.lastPathComponent) (\(size) bytes)"],
                ],
                structuredContent: ["path": url.path, "bytes": size]
            )
        }
        let result: [String: Any] = [
            "path": url.path,
            "filename": url.lastPathComponent,
            "bytes": size,
            "mime_type": type?.preferredMIMEType ?? "application/octet-stream",
            "note": "The attachment is not an image, so only local file metadata is returned.",
        ]
        return jsonResult(result)
    }

    private func sendMessage(_ args: [String: Any]) throws -> ToolCallResult {
        let current = settings.value
        guard current.writesEnabled else {
            throw ToolServiceError.disabled("Message sending is disabled in the iMessage MCP menu.")
        }
        let chatID = optionalInt64(args, "chat_id")
        let recipient = optionalString(args, "to")
        guard (chatID == nil) != (recipient == nil) else {
            throw ToolServiceError.invalid("Provide exactly one of chat_id or to.")
        }
        let text = optionalStringAllowEmpty(args, "text")
        let file = optionalString(args, "file")
        guard text != nil || file != nil else {
            throw ToolServiceError.invalid("Provide text, file, or both.")
        }
        if let file {
            try validateOutboundFile(file, maximumBytes: current.maxAttachmentBytes)
        }
        let targetLabel = chatID.flatMap(approvalLabel(chatID:))
            ?? recipient
            ?? chatID.map { "chat \($0)" }
            ?? "recipient"
        let preview = text.map { String($0.prefix(120)) } ?? "(attachment only)"
        let detail = preview
            + (file.map { "\nAttachment: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "")
        if current.confirmSends && !approvals.requestApproval(
            kind: .send,
            title: "Send to \(targetLabel)?",
            detail: detail,
            timeout: 120
        ) {
            throw ToolServiceError.denied
        }

        let service = try enumValue(args, "service", default: "auto", allowed: ["auto", "imessage", "sms"])
        let noSMSFallback = bool(args, "no_sms_fallback", default: false)
        let result: Any
        if noSMSFallback {
            // imsg's RPC send does not expose this flag. Keep exact routing semantics
            // through the CLI even though its returned GUID is less often available.
            var command = ["send"]
            if let chatID { command += ["--chat-id", "\(chatID)"] }
            if let recipient { command += ["--to", recipient] }
            if let text { command += ["--text", text] }
            if let file { command += ["--file", URL(fileURLWithPath: file).standardizedFileURL.path] }
            command += ["--service", service, "--no-sms-fallback"]
            if let region = optionalString(args, "region") { command += ["--region", region] }
            result = try runJSON(command, timeout: 60)
        } else {
            var params: [String: Any] = [
                "service": service,
                "transport": "applescript",
            ]
            if let chatID { params["chat_id"] = chatID }
            if let recipient { params["to"] = recipient }
            if let text { params["text"] = text }
            if let file { params["file"] = URL(fileURLWithPath: file).standardizedFileURL.path }
            if let region = optionalString(args, "region") { params["region"] = region }
            result = try runner.rpc(method: "send", params: params, timeout: 60)
        }
        activity.append(ActivityEntry(
            kind: .send,
            title: "Message sent",
            detail: targetLabel
        ))
        return jsonResult(result)
    }

    private func react(_ args: [String: Any]) throws -> ToolCallResult {
        let current = settings.value
        guard current.writesEnabled else {
            throw ToolServiceError.disabled("Reactions are disabled because writes are disabled in the menu.")
        }
        let chatID = try int64(args, "chat_id", minimum: 1)
        let reaction = try enumValue(
            args,
            "reaction",
            allowed: ["love", "like", "dislike", "laugh", "emphasis", "question"]
        )
        if let expected = optionalString(args, "expected_message_guid") {
            let history = try runJSON(["history", "--chat-id", "\(chatID)", "--limit", "20"])
            guard let actual = mostRecentIncomingGUID(in: history) else {
                throw ToolServiceError.invalid("No recent incoming message was found in chat \(chatID).")
            }
            guard actual == expected else {
                throw ToolServiceError.invalid(
                    "The latest incoming message changed. Expected \(expected), found \(actual). Read the chat again before reacting."
                )
            }
        }
        let targetLabel = approvalLabel(chatID: chatID) ?? "chat \(chatID)"
        let detail = "\(reaction.capitalized) · \(targetLabel)\nTargets the most recent incoming message."
        if current.confirmReactions && !approvals.requestApproval(
            kind: .reaction,
            title: "Add \(reaction) tapback for \(targetLabel)?",
            detail: detail,
            timeout: 120
        ) {
            throw ToolServiceError.denied
        }
        let result = try runJSON([
            "react", "--chat-id", "\(chatID)", "--reaction", reaction,
        ], timeout: 30)
        activity.append(ActivityEntry(
            kind: .reaction,
            title: "Tapback sent",
            detail: "\(targetLabel) · \(reaction)"
        ))
        return jsonResult(result)
    }

    private func sendStatus(_ args: [String: Any]) throws -> ToolCallResult {
        let guid = try requiredString(args, "guid")
        let result = try runner.rpc(method: "message.send_status", params: ["guid": guid], timeout: 20)
        logRead("Checked send status", detail: guid)
        return jsonResult(result)
    }

    private func runJSON(_ arguments: [String], timeout: TimeInterval = 30) throws -> Any {
        var command = arguments
        if !command.contains("--json") { command.append("--json") }
        let output = try runner.run(arguments: command, timeout: timeout)
        return output.jsonValue
    }

    private func jsonResult(_ value: Any) -> ToolCallResult {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(describing: value)
        return .text(text, structured: value)
    }

    private func logRead(_ title: String, detail: String) {
        activity.append(ActivityEntry(kind: .read, title: title, detail: detail))
    }

    private func approvalLabel(chatID: Int64) -> String? {
        let group = try? runJSON(["group", "--chat-id", "\(chatID)"])
        if let group,
           let friendly = preferredChatLabel(in: group, includeRoutingIdentifiers: false) {
            return friendly
        }
        if let chats = try? runJSON(["chats", "--limit", "200"]),
           let matching = chatObject(withID: chatID, in: chats),
           let listed = preferredChatLabel(in: matching, includeRoutingIdentifiers: true) {
            return listed
        }
        return group.flatMap {
            preferredChatLabel(in: $0, includeRoutingIdentifiers: true)
        }
    }

    private func preferredChatLabel(in value: Any, includeRoutingIdentifiers: Bool) -> String? {
        if let object = value as? [String: Any] {
            let keys = includeRoutingIdentifiers
                ? ["display_name", "name", "contact_name", "identifier"]
                : ["display_name", "name", "contact_name"]
            for key in keys {
                if let text = object[key] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            if let participants = object["participants"] as? [String], participants.count > 1 {
                return participants.prefix(3).joined(separator: ", ")
            }
            for nested in object.values {
                if let label = preferredChatLabel(
                    in: nested,
                    includeRoutingIdentifiers: includeRoutingIdentifiers
                ) {
                    return label
                }
            }
        } else if let values = value as? [Any] {
            for nested in values {
                if let label = preferredChatLabel(
                    in: nested,
                    includeRoutingIdentifiers: includeRoutingIdentifiers
                ) {
                    return label
                }
            }
        }
        return nil
    }

    private func chatObject(withID chatID: Int64, in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if (object["id"] as? NSNumber)?.int64Value == chatID {
                return object
            }
            for nested in object.values {
                if let match = chatObject(withID: chatID, in: nested) { return match }
            }
        } else if let values = value as? [Any] {
            for nested in values {
                if let match = chatObject(withID: chatID, in: nested) { return match }
            }
        }
        return nil
    }

    private func validateOutboundFile(_ path: String, maximumBytes: Int) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ToolServiceError.invalid("Attachment must be an existing regular file.")
        }
        if (values.fileSize ?? 0) > maximumBytes {
            throw ToolServiceError.invalid("Attachment exceeds the configured size limit.")
        }
    }

    private func mostRecentIncomingGUID(in value: Any) -> String? {
        let objects: [[String: Any]]
        if let array = value as? [[String: Any]] {
            objects = array
        } else if let dictionary = value as? [String: Any],
                  let messages = dictionary["messages"] as? [[String: Any]] {
            objects = messages
        } else {
            objects = []
        }
        return objects
            .filter { ($0["is_from_me"] as? Bool) == false }
            .sorted {
                (($0["created_at"] as? String) ?? "") > (($1["created_at"] as? String) ?? "")
            }
            .first?["guid"] as? String
    }

    private func resultCount(_ value: Any) -> Int {
        if let array = value as? [Any] { return array.count }
        if let dictionary = value as? [String: Any] {
            for key in ["messages", "chats", "results"] {
                if let array = dictionary[key] as? [Any] { return array.count }
            }
        }
        return 0
    }
}

// MARK: - JSON schema helpers

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

private func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> [String: Any] {
    var value: [String: Any] = ["type": "integer", "description": description]
    if let minimum { value["minimum"] = minimum }
    if let maximum { value["maximum"] = maximum }
    return value
}

private func boolean(_ description: String) -> [String: Any] {
    ["type": "boolean", "description": description]
}

// MARK: - Argument validation

private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ToolServiceError.invalid("\(key) is required.")
    }
    return value
}

private func optionalString(_ args: [String: Any], _ key: String) -> String? {
    guard let value = args[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : value
}

private func optionalStringAllowEmpty(_ args: [String: Any], _ key: String) -> String? {
    args[key] as? String
}

private func bool(_ args: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
    args[key] as? Bool ?? defaultValue
}

private func int(
    _ args: [String: Any],
    _ key: String,
    default defaultValue: Int,
    range: ClosedRange<Int>
) throws -> Int {
    guard let raw = args[key] else { return defaultValue }
    guard let value = (raw as? NSNumber)?.intValue, range.contains(value) else {
        throw ToolServiceError.invalid("\(key) must be between \(range.lowerBound) and \(range.upperBound).")
    }
    return value
}

private func int64(_ args: [String: Any], _ key: String, minimum: Int64) throws -> Int64 {
    guard let value = optionalInt64(args, key), value >= minimum else {
        throw ToolServiceError.invalid("\(key) must be at least \(minimum).")
    }
    return value
}

private func optionalInt64(_ args: [String: Any], _ key: String) -> Int64? {
    (args[key] as? NSNumber)?.int64Value
}

private func enumValue(
    _ args: [String: Any],
    _ key: String,
    default defaultValue: String? = nil,
    allowed: [String]
) throws -> String {
    if args[key] == nil, let defaultValue { return defaultValue }
    guard let value = args[key] as? String, allowed.contains(value) else {
        throw ToolServiceError.invalid("\(key) must be one of: \(allowed.joined(separator: ", ")).")
    }
    return value
}
