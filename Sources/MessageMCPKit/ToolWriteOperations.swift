import Foundation

extension ToolService {
    func sendMessage(_ args: [String: Any]) throws -> ToolCallResult {
        let current = settings.value
        guard current.writesEnabled else {
            throw ToolServiceError.disabled(
                "Message sending is disabled in the iMessage MCP menu."
            )
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
        let targetLabel =
            chatID.flatMap(approvalLabel(chatID:))
            ?? recipient
            ?? chatID.map { "chat \($0)" }
            ?? "recipient"
        let preview = text.map { String($0.prefix(120)) } ?? "(attachment only)"
        let detail =
            preview
            + (file.map {
                "\nAttachment: \(URL(fileURLWithPath: $0).lastPathComponent)"
            } ?? "")
        if current.confirmSends
            && !approvals.requestApproval(
                kind: .send,
                title: "Send to \(targetLabel)?",
                detail: detail,
                timeout: 120
            )
        {
            throw ToolServiceError.denied
        }

        let service = try enumValue(
            args,
            "service",
            default: "auto",
            allowed: ["auto", "imessage", "sms"]
        )
        let noSMSFallback = bool(args, "no_sms_fallback", default: false)
        let result: Any
        if noSMSFallback {
            // imsg's RPC send does not expose this flag. Keep exact routing semantics
            // through the CLI even though its returned GUID is less often available.
            var command = ["send"]
            if let chatID { command += ["--chat-id", "\(chatID)"] }
            if let recipient { command += ["--to", recipient] }
            if let text { command += ["--text", text] }
            if let file {
                command += [
                    "--file",
                    URL(fileURLWithPath: file).standardizedFileURL.path,
                ]
            }
            command += ["--service", service, "--no-sms-fallback"]
            if let region = optionalString(args, "region") {
                command += ["--region", region]
            }
            result = try runJSON(command, timeout: 60)
        } else {
            var params: [String: Any] = [
                "service": service,
                "transport": "applescript",
            ]
            if let chatID { params["chat_id"] = chatID }
            if let recipient { params["to"] = recipient }
            if let text { params["text"] = text }
            if let file {
                params["file"] = URL(fileURLWithPath: file).standardizedFileURL.path
            }
            if let region = optionalString(args, "region") { params["region"] = region }
            result = try runner.rpc(method: "send", params: params, timeout: 60)
        }
        activity.append(
            ActivityEntry(
                kind: .send,
                title: "Message sent",
                detail: targetLabel
            )
        )
        return jsonResult(result)
    }

    func react(_ args: [String: Any]) throws -> ToolCallResult {
        let current = settings.value
        guard current.writesEnabled else {
            throw ToolServiceError.disabled(
                "Reactions are disabled because writes are disabled in the menu."
            )
        }
        let chatID = try int64(args, "chat_id", minimum: 1)
        let reaction = try enumValue(
            args,
            "reaction",
            allowed: ["love", "like", "dislike", "laugh", "emphasis", "question"]
        )
        if let expected = optionalString(args, "expected_message_guid") {
            let history = try runJSON([
                "history", "--chat-id", "\(chatID)", "--limit", "20",
            ])
            guard let actual = mostRecentIncomingGUID(in: history) else {
                throw ToolServiceError.invalid(
                    "No recent incoming message was found in chat \(chatID)."
                )
            }
            guard actual == expected else {
                throw ToolServiceError.invalid(
                    "The latest incoming message changed. Expected \(expected), found \(actual). Read the chat again before reacting."
                )
            }
        }
        let targetLabel = approvalLabel(chatID: chatID) ?? "chat \(chatID)"
        let detail =
            "\(reaction.capitalized) · \(targetLabel)\nTargets the most recent incoming message."
        if current.confirmReactions
            && !approvals.requestApproval(
                kind: .reaction,
                title: "Add \(reaction) tapback for \(targetLabel)?",
                detail: detail,
                timeout: 120
            )
        {
            throw ToolServiceError.denied
        }
        let result = try runJSON(
            [
                "react", "--chat-id", "\(chatID)", "--reaction", reaction,
            ], timeout: 30)
        activity.append(
            ActivityEntry(
                kind: .reaction,
                title: "Tapback sent",
                detail: "\(targetLabel) · \(reaction)"
            )
        )
        return jsonResult(result)
    }

    func sendStatus(_ args: [String: Any]) throws -> ToolCallResult {
        let guid = try requiredString(args, "guid")
        let result = try runner.rpc(
            method: "message.send_status",
            params: ["guid": guid],
            timeout: 20
        )
        logRead("Checked send status", detail: guid)
        return jsonResult(result)
    }
}
