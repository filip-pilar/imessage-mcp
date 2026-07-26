import Foundation
import UniformTypeIdentifiers

extension ToolService {
    func checkSetup() throws -> ToolCallResult {
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
        activity.append(
            ActivityEntry(
                kind: .diagnostic,
                title: "Setup checked",
                detail: "imsg \(version)"
            )
        )
        return jsonResult(result)
    }

    func listChats(_ args: [String: Any]) throws -> ToolCallResult {
        var command = [
            "chats", "--limit",
            "\(try int(args, "limit", default: 20, range: 1...200))",
        ]
        if bool(args, "unread_only", default: false) { command.append("--unread-only") }
        let result = try runJSON(command)
        logRead(
            "Listed chats",
            detail: bool(args, "unread_only", default: false) ? "Unread only" : "Recent"
        )
        return jsonResult(result)
    }

    func getChat(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        let result = try runJSON(["group", "--chat-id", "\(chatID)"])
        logRead("Read chat", detail: "Chat \(chatID)")
        return jsonResult(result)
    }

    func getChatBackground(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        let result = try runJSON(["chat-background", "status", "--chat-id", "\(chatID)"])
        logRead("Read chat background", detail: "Chat \(chatID)")
        return jsonResult(result)
    }

    func getMessages(_ args: [String: Any]) throws -> ToolCallResult {
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

    func searchMessages(_ args: [String: Any]) throws -> ToolCallResult {
        let query = try requiredString(args, "query")
        let match = try enumValue(
            args,
            "match",
            default: "contains",
            allowed: ["contains", "exact"]
        )
        let limit = try int(args, "limit", default: 50, range: 1...500)
        let result = try runJSON([
            "search", "--query", query, "--match", match, "--limit", "\(limit)",
        ])
        logRead("Searched messages", detail: "\(resultCount(result)) results")
        return jsonResult(result)
    }

    func statistics(_ args: [String: Any]) throws -> ToolCallResult {
        var params: [String: Any] = [
            "include_media": bool(args, "include_media", default: false)
        ]
        if let chatID = optionalInt64(args, "chat_id") { params["chat_id"] = chatID }
        if let zone = optionalString(args, "time_zone") { params["time_zone"] = zone }
        let result = try runner.rpc(method: "messages.stats", params: params, timeout: 30)
        logRead(
            "Calculated statistics",
            detail: optionalInt64(args, "chat_id").map { "Chat \($0)" } ?? "All chats"
        )
        return jsonResult(result)
    }

    func scheduled(_ args: [String: Any]) throws -> ToolCallResult {
        let limit = try int(args, "limit", default: 50, range: 1...200)
        let result = try runJSON(["scheduled", "list", "--limit", "\(limit)"])
        logRead("Listed scheduled messages", detail: "\(resultCount(result)) results")
        return jsonResult(result)
    }

    func localAccounts() throws -> ToolCallResult {
        let result = try runJSON(["account", "--local"])
        logRead("Listed local accounts", detail: "Historical Messages accounts")
        return jsonResult(result)
    }

    func lookupHandle(_ args: [String: Any]) throws -> ToolCallResult {
        let address = try requiredString(args, "address")
        let service = try runJSON(["whois", "--address", address, "--local"])
        let contact = try runJSON(["nickname", "--address", address, "--local"])
        let result: [String: Any] = [
            "address": address,
            "service_history": service,
            "local_contact": contact,
            "note":
                "Service is inferred from local history; the name is from this Mac's Contacts, not a live iMessage lookup.",
        ]
        logRead("Looked up handle", detail: address)
        return jsonResult(result)
    }

    func readAttachment(_ args: [String: Any]) throws -> ToolCallResult {
        let rawPath = try requiredString(args, "path")
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
        guard
            url.path.hasPrefix(
                FileManager.default.homeDirectoryForCurrentUser.path
                    + "/Library/Messages/Attachments/"
            )
                || url.path.hasPrefix(AppPaths.applicationSupport.path + "/")
                || url.path.hasPrefix(
                    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
                        + "/"
                )
        else {
            throw ToolServiceError.invalid(
                "Only Messages attachments and imsg-generated cache files can be read."
            )
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]
        )
        guard values.isRegularFile == true else {
            throw ToolServiceError.invalid("Attachment is not a regular file.")
        }
        let size = values.fileSize ?? 0
        guard size <= 20 * 1_024 * 1_024 else {
            throw ToolServiceError.invalid(
                "Attachment is larger than the 20 MB MCP read limit."
            )
        }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            logRead("Read attachment", detail: "\(url.lastPathComponent) · \(size) bytes")
            return ToolCallResult(
                content: [
                    [
                        "type": "image",
                        "data": data.base64EncodedString(),
                        "mimeType": type.preferredMIMEType ?? "image/png",
                    ],
                    [
                        "type": "text",
                        "text": "\(url.lastPathComponent) (\(size) bytes)",
                    ],
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
}
