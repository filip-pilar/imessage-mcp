import Foundation

extension ToolService {
    func newMessages(_ args: [String: Any]) throws -> ToolCallResult {
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

    func waitForMessage(_ args: [String: Any]) throws -> ToolCallResult {
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
                    cursor =
                        LiveEventCursor(
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
        let eventChatID =
            (object["chat_id"] as? NSNumber)?.int64Value
            ?? (object["chat_id"] as? String).flatMap(Int64.init)
        guard eventChatID == chatID else { return false }
        if object["is_reaction"] as? Bool == true { return false }
        if let type = object["type"] as? String,
            type.lowercased().contains("reaction")
        {
            return false
        }
        if object["is_from_me"] as? Bool == true { return false }
        return true
    }
}
