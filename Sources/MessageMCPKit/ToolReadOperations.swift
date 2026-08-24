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
        activity.append(kind: .diagnostic)
        return jsonResult(result)
    }

    func listChats(_ args: [String: Any]) throws -> ToolCallResult {
        var command = [
            "chats", "--limit",
            "\(try int(args, "limit", default: 20, range: 1...200))",
        ]
        if bool(args, "unread_only", default: false) { command.append("--unread-only") }
        let result = try runJSON(command)
        activity.append(kind: .read)
        return jsonResult(result)
    }

    func getChat(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        let result = try runJSON(["group", "--chat-id", "\(chatID)"])
        activity.append(kind: .read)
        return jsonResult(result)
    }

    func getChatBackground(_ args: [String: Any]) throws -> ToolCallResult {
        let chatID = try int64(args, "chat_id", minimum: 1)
        let result = try runJSON(["chat-background", "status", "--chat-id", "\(chatID)"])
        activity.append(kind: .read)
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
        activity.append(kind: .read)
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
        activity.append(kind: .read)
        return jsonResult(result)
    }

    func statistics(_ args: [String: Any]) throws -> ToolCallResult {
        var params: [String: Any] = [
            "include_media": bool(args, "include_media", default: false)
        ]
        if let chatID = optionalInt64(args, "chat_id") { params["chat_id"] = chatID }
        if let zone = optionalString(args, "time_zone") { params["time_zone"] = zone }
        let result = try runner.rpc(method: "messages.stats", params: params, timeout: 30)
        activity.append(kind: .read)
        return jsonResult(result)
    }

    func scheduled(_ args: [String: Any]) throws -> ToolCallResult {
        let limit = try int(args, "limit", default: 50, range: 1...200)
        let result = try runJSON(["scheduled", "list", "--limit", "\(limit)"])
        activity.append(kind: .read)
        return jsonResult(result)
    }

    func localAccounts() throws -> ToolCallResult {
        let result = try runJSON(["account", "--local"])
        activity.append(kind: .read)
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
        activity.append(kind: .read)
        return jsonResult(result)
    }

    func readAttachment(_ args: [String: Any]) throws -> ToolCallResult {
        try readAttachment(args, allowedRoots: Self.defaultAttachmentReadRoots)
    }

    func readAttachment(
        _ args: [String: Any],
        allowedRoots: [URL],
        beforeRead: (() throws -> Void)? = nil
    ) throws -> ToolCallResult {
        let rawPath = try requiredString(args, "path")
        guard NSString(string: rawPath).isAbsolutePath else {
            throw ToolServiceError.invalid("Attachment path must be absolute.")
        }
        let url = URL(fileURLWithPath: NSString(string: rawPath).standardizingPath)
        guard let root = allowedRoots.first(where: { Self.contains(url, root: $0) }) else {
            throw ToolServiceError.invalid(
                "Only Messages attachments and imsg-generated converted attachments can be read."
            )
        }
        let maximumBytes = 20 * 1_024 * 1_024
        let descriptor: SecureFileDescriptor
        let metadata: SecureFileMetadata
        do {
            descriptor = try SecureFileIO.openFile(at: url, beneath: root)
            metadata = try SecureFileIO.regularFileMetadata(
                for: descriptor,
                maximumBytes: maximumBytes
            )
        } catch SecureFileIOError.tooLarge {
            throw ToolServiceError.invalid("Attachment is larger than the 20 MB MCP read limit.")
        } catch SecureFileIOError.notRegular {
            throw ToolServiceError.invalid("Attachment is not a regular file.")
        } catch {
            throw ToolServiceError.invalid(
                "Attachment could not be opened safely inside an allowed directory."
            )
        }
        let size = metadata.byteCount
        let type = contentTypeForFilename(url)
        if type.conforms(to: .image) {
            try beforeRead?()
            let data: Data
            do {
                data = try SecureFileIO.read(
                    from: descriptor,
                    maximumBytes: maximumBytes
                )
            } catch SecureFileIOError.tooLarge {
                throw ToolServiceError.invalid(
                    "Attachment grew beyond the 20 MB MCP read limit while it was being read."
                )
            } catch {
                throw ToolServiceError.invalid("Attachment could not be read safely.")
            }
            let returnedSize = data.count
            activity.append(kind: .read)
            return ToolCallResult(
                content: [
                    [
                        "type": "image",
                        "data": data.base64EncodedString(),
                        "mimeType": type.preferredMIMEType ?? "image/png",
                    ],
                    [
                        "type": "text",
                        "text": "\(url.lastPathComponent) (\(returnedSize) bytes)",
                    ],
                ],
                structuredContent: ["path": url.path, "bytes": returnedSize]
            )
        }
        let result: [String: Any] = [
            "path": url.path,
            "filename": url.lastPathComponent,
            "bytes": size,
            "mime_type": type.preferredMIMEType ?? "application/octet-stream",
            "note": "The attachment is not an image, so only local file metadata is returned.",
        ]
        return jsonResult(result)
    }

    static var defaultAttachmentReadRoots: [URL] {
        let fileManager = FileManager.default
        return attachmentReadRoots(
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
    }

    static func attachmentReadRoots(
        homeDirectory: URL
    ) -> [URL] {
        let canonicalHome =
            (try? SecureFileIO.canonicalExistingURL(homeDirectory.standardizedFileURL))
            ?? homeDirectory.standardizedFileURL
        return [
            canonicalHome
                .appendingPathComponent("Library/Messages/Attachments", isDirectory: true),
            canonicalHome
                .appendingPathComponent(
                    "Library/Caches/imsg/converted-attachments",
                    isDirectory: true
                ),
        ]
    }

    private static func contains(_ url: URL, root: URL) -> Bool {
        let filePath = canonicalSystemAliasPath(url.path)
        let rootPath = canonicalSystemAliasPath(root.path)
        guard filePath != rootPath else { return true }
        return filePath.hasPrefix(rootPath + "/")
    }

    private static func canonicalSystemAliasPath(_ path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/") {
            return "/private" + path
        }
        return path
    }
}
