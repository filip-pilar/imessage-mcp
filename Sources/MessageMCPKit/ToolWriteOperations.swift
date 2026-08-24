import Foundation

extension ToolService {
    func sendMessage(
        _ args: [String: Any],
        context: ToolCallContext = ToolCallContext()
    ) throws -> ToolCallResult {
        let policySnapshot = settings.writePolicySnapshot
        let initialPolicy = policySnapshot.settings
        guard initialPolicy.writesEnabled else {
            throw ToolServiceError.disabled(
                "Message sending is disabled in the iMessage MCP menu."
            )
        }
        try context.ensureActive()
        let intent = try normalizeSendIntent(
            args,
            maximumAttachmentBytes: initialPolicy.maxAttachmentBytes,
            cancellation: context.cancellation
        )
        defer {
            if let attachment = intent.attachment {
                finishStagedAttachment(attachment)
            }
        }
        try context.ensureActive()

        var wasApproved = false
        if initialPolicy.confirmSends {
            wasApproved = try approvals.requestApproval(
                kind: .send,
                title: sendApprovalTitle(for: intent),
                detail: sendApprovalDetail(for: intent),
                timeout: 120,
                cancellation: context.cancellation
            )
            try context.ensureActive()
            guard wasApproved else { throw ToolServiceError.denied }
        }

        let currentPolicy = settings.value
        if let attachment = intent.attachment {
            try revalidateAttachment(
                attachment,
                maximumBytes: currentPolicy.maxAttachmentBytes
            )
        }
        try requireSendPolicy(wasApproved: wasApproved, snapshot: policySnapshot)
        try context.ensureActive()

        let result: Any
        if intent.preventsSMSFallback {
            result = try runJSON(sendCommand(for: intent), timeout: 60)
        } else {
            result = try runner.rpc(
                method: "send",
                params: sendParameters(for: intent),
                timeout: 60
            )
        }
        activity.append(kind: .send)
        return jsonResult(result)
    }

    func react(
        _ args: [String: Any],
        context: ToolCallContext = ToolCallContext()
    ) throws -> ToolCallResult {
        let policySnapshot = settings.writePolicySnapshot
        let initialPolicy = policySnapshot.settings
        let intent = try normalizeReactionIntent(args)
        guard initialPolicy.writesEnabled else {
            throw ToolServiceError.disabled(
                "Reactions are disabled because writes are disabled in the menu."
            )
        }
        try context.ensureActive()
        try verifyReactionTarget(intent)

        var wasApproved = false
        if initialPolicy.confirmReactions {
            let targetLabel = approvalLabel(chatID: intent.chatID)
                .map { "\(approvalQuoted($0)) (chat_id: \(intent.chatID))" }
                ?? "chat_id: \(intent.chatID)"
            wasApproved = try approvals.requestApproval(
                kind: .reaction,
                title: "Add \(intent.reaction) tapback?",
                detail: [
                    "Target: \(targetLabel)",
                    "Expected message GUID: \(approvalQuoted(intent.expectedMessageGUID))",
                    "Reaction: \(intent.reaction)",
                    "Targets the most recent incoming message only if its GUID still matches.",
                ].joined(separator: "\n"),
                timeout: 120,
                cancellation: context.cancellation
            )
            try context.ensureActive()
            guard wasApproved else { throw ToolServiceError.denied }
        }

        try verifyReactionTarget(intent)
        try requireReactionPolicy(wasApproved: wasApproved, snapshot: policySnapshot)
        try context.ensureActive()
        let result = try runJSON(
            [
                "react", "--chat-id", "\(intent.chatID)",
                "--reaction", intent.reaction,
            ],
            timeout: 30
        )
        activity.append(kind: .reaction)
        return jsonResult(result)
    }

    func sendStatus(_ args: [String: Any]) throws -> ToolCallResult {
        let guid = try requiredString(args, "guid")
        let result = try runner.rpc(
            method: "message.send_status",
            params: ["guid": guid],
            timeout: 20
        )
        activity.append(kind: .read)
        return jsonResult(result)
    }

    private func sendApprovalTitle(for intent: SendMessageIntent) -> String {
        switch intent.target {
        case .chat(let chatID):
            if let label = approvalLabel(chatID: chatID) {
                return "Send to \(approvalQuoted(label)) (chat_id: \(chatID))?"
            }
            return "Send to chat_id \(chatID)?"
        case .address(let address):
            return "Send to \(approvalQuoted(address))?"
        }
    }

    private func sendApprovalDetail(for intent: SendMessageIntent) -> String {
        var lines = [
            "Target: \(approvalQuoted(intent.target.canonicalDescription))",
            "Service: \(intent.service.rawValue)",
            "SMS fallback: \(intent.preventsSMSFallback ? "blocked" : "allowed")",
        ]
        if let attachment = intent.attachment {
            lines += [
                "Attachment: \(approvalQuoted(attachment.sourceURL.path))",
                "Attachment type: \(approvalQuoted(attachment.typeIdentifier))",
                "Attachment size: \(attachment.byteCount) bytes",
            ]
        } else {
            lines.append("Attachment: (none)")
        }
        lines.append(
            "Message: \(intent.text.map(approvalQuoted) ?? "(none)")"
        )
        return lines.joined(separator: "\n")
    }

    private func sendCommand(for intent: SendMessageIntent) -> [String] {
        var command = ["send"]
        switch intent.target {
        case .chat(let chatID):
            command += ["--chat-id", "\(chatID)"]
        case .address(let address):
            command += ["--to", address]
        }
        if let text = intent.text { command += ["--text", text] }
        if let attachment = intent.attachment {
            command += ["--file", attachment.stagedURL.path]
        }
        command += [
            "--service", intent.service.rawValue,
            "--no-sms-fallback",
        ]
        return command
    }

    private func sendParameters(for intent: SendMessageIntent) -> [String: Any] {
        var params: [String: Any] = [
            "service": intent.service.rawValue,
            "transport": "applescript",
        ]
        switch intent.target {
        case .chat(let chatID):
            params["chat_id"] = chatID
        case .address(let address):
            params["to"] = address
        }
        if let text = intent.text { params["text"] = text }
        if let attachment = intent.attachment {
            params["file"] = attachment.stagedURL.path
        }
        return params
    }

    private func requireSendPolicy(
        wasApproved: Bool,
        snapshot: WritePolicySnapshot
    ) throws {
        guard let current = settings.currentWritePolicy(matching: snapshot) else {
            throw ToolServiceError.disabled(
                "Write settings changed while the message was pending. Review and retry it."
            )
        }
        guard current.writesEnabled else {
            throw ToolServiceError.disabled(
                "Message sending was disabled before execution."
            )
        }
        guard !current.confirmSends || wasApproved else {
            throw ToolServiceError.denied
        }
    }

    private func requireReactionPolicy(
        wasApproved: Bool,
        snapshot: WritePolicySnapshot
    ) throws {
        guard let current = settings.currentWritePolicy(matching: snapshot) else {
            throw ToolServiceError.disabled(
                "Write settings changed while the tapback was pending. Review and retry it."
            )
        }
        guard current.writesEnabled else {
            throw ToolServiceError.disabled(
                "Reactions were disabled before execution."
            )
        }
        guard !current.confirmReactions || wasApproved else {
            throw ToolServiceError.denied
        }
    }

    private func verifyReactionTarget(_ intent: ReactionIntent) throws {
        let history = try runJSON([
            "history", "--chat-id", "\(intent.chatID)", "--limit", "20",
        ])
        guard let actual = mostRecentIncomingGUID(in: history) else {
            throw ToolServiceError.invalid(
                "No recent incoming message was found in chat \(intent.chatID)."
            )
        }
        guard actual == intent.expectedMessageGUID else {
            throw ToolServiceError.invalid(
                "The latest incoming message changed. Expected \(intent.expectedMessageGUID), found \(actual). Read the chat again before reacting."
            )
        }
    }
}

private func approvalQuoted(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22: result += "\\\""
        case 0x5C: result += "\\\\"
        case 0x0A: result += "\\n"
        case 0x0D: result += "\\r"
        case 0x09: result += "\\t"
        case 0x00...0x1F, 0x7F...0x9F, 0x061C,
            0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFEFF:
            result += String(format: "\\u{%04X}", scalar.value)
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    result.append("\"")
    return result
}
