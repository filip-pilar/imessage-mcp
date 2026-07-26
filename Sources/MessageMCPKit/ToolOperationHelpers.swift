import Foundation

extension ToolService {
    func runJSON(_ arguments: [String], timeout: TimeInterval = 30) throws -> Any {
        var command = arguments
        if !command.contains("--json") { command.append("--json") }
        let output = try runner.run(arguments: command, timeout: timeout)
        return output.jsonValue
    }

    func jsonResult(_ value: Any) -> ToolCallResult {
        let data =
            (try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(describing: value)
        return .text(text, structured: value)
    }

    func logRead(_ title: String, detail: String) {
        activity.append(ActivityEntry(kind: .read, title: title, detail: detail))
    }

    func approvalLabel(chatID: Int64) -> String? {
        let group = try? runJSON(["group", "--chat-id", "\(chatID)"])
        if let group,
            let friendly = preferredChatLabel(
                in: group,
                includeRoutingIdentifiers: false
            )
        {
            return friendly
        }
        if let chats = try? runJSON(["chats", "--limit", "200"]),
            let matching = chatObject(withID: chatID, in: chats),
            let listed = preferredChatLabel(
                in: matching,
                includeRoutingIdentifiers: true
            )
        {
            return listed
        }
        return group.flatMap {
            preferredChatLabel(in: $0, includeRoutingIdentifiers: true)
        }
    }

    private func preferredChatLabel(
        in value: Any,
        includeRoutingIdentifiers: Bool
    ) -> String? {
        if let object = value as? [String: Any] {
            let keys =
                includeRoutingIdentifiers
                ? ["display_name", "name", "contact_name", "identifier"]
                : ["display_name", "name", "contact_name"]
            for key in keys {
                if let text = object[key] as? String,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return text
                }
            }
            if let participants = object["participants"] as? [String],
                participants.count > 1
            {
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

    func validateOutboundFile(_ path: String, maximumBytes: Int) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ToolServiceError.invalid(
                "Attachment must be an existing regular file."
            )
        }
        if (values.fileSize ?? 0) > maximumBytes {
            throw ToolServiceError.invalid(
                "Attachment exceeds the configured size limit."
            )
        }
    }

    func mostRecentIncomingGUID(in value: Any) -> String? {
        let objects: [[String: Any]]
        if let array = value as? [[String: Any]] {
            objects = array
        } else if let dictionary = value as? [String: Any],
            let messages = dictionary["messages"] as? [[String: Any]]
        {
            objects = messages
        } else {
            objects = []
        }
        return
            objects
            .filter { ($0["is_from_me"] as? Bool) == false }
            .sorted {
                (($0["created_at"] as? String) ?? "")
                    > (($1["created_at"] as? String) ?? "")
            }
            .first?["guid"] as? String
    }

    func resultCount(_ value: Any) -> Int {
        if let array = value as? [Any] { return array.count }
        if let dictionary = value as? [String: Any] {
            for key in ["messages", "chats", "results"] {
                if let array = dictionary[key] as? [Any] { return array.count }
            }
        }
        return 0
    }
}
