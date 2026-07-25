import Foundation
import Testing
@testable import MessageMCPKit

private final class LockedToolResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ToolCallResult?

    var value: ToolCallResult? { lock.withLock { storage } }
    func set(_ value: ToolCallResult) { lock.withLock { storage = value } }
}

@Suite("MCP tool service")
struct ToolServiceTests {
    @Test("tool catalog is valid JSON and names are unique")
    func catalog() throws {
        let objects = ToolService.tools.map(\.jsonObject)
        #expect(Set(ToolService.tools.map(\.name)).count == ToolService.tools.count)
        #expect(JSONSerialization.isValidJSONObject(objects))
        #expect(ToolService.tools.count >= 12)
    }

    @Test("setup check includes live app readiness")
    func setupReadiness() throws {
        let env = try TestEnvironment()
        let service = ToolService(
            runner: FakeRunner(),
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove(),
            statusProvider: {
                [
                    "database_ready": true,
                    "accessibility_ready": true,
                    "live_events_running": true,
                    "active_client_count": 1,
                ]
            }
        )

        let result = service.call(name: "check_setup", arguments: [:])
        let structured = result.structuredContent?.value as? [String: Any]
        #expect(structured?["database_ready"] as? Bool == true)
        #expect(structured?["accessibility_ready"] as? Bool == true)
        #expect(structured?["live_events_running"] as? Bool == true)
        #expect((structured?["active_client_count"] as? NSNumber)?.intValue == 1)
    }

    @Test("read operations map to documented imsg arguments")
    func reads() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        runner.defaultResponse = CommandOutput(stdout: #"{"chat_id":42}"# + "\n")
        let service = env.service(runner: runner)

        let result = service.call(name: "get_messages", arguments: [
            "chat_id": 42,
            "limit": 25,
            "attachments": true,
            "convert_attachments": true,
        ])

        #expect(!result.isError)
        #expect(runner.calls.last?.arguments == [
            "history", "--chat-id", "42", "--limit", "25",
            "--attachments", "--convert-attachments", "--json",
        ])
    }

    @Test("SIP-safe supplemental reads use local-only imsg modes")
    func localReads() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let service = env.service(runner: runner)

        #expect(!service.call(
            name: "list_scheduled_messages",
            arguments: ["limit": 12]
        ).isError)
        #expect(runner.calls.last?.arguments == [
            "scheduled", "list", "--limit", "12", "--json",
        ])

        #expect(!service.call(name: "list_local_accounts", arguments: [:]).isError)
        #expect(runner.calls.last?.arguments == ["account", "--local", "--json"])

        #expect(!service.call(
            name: "get_chat_background",
            arguments: ["chat_id": 9]
        ).isError)
        #expect(runner.calls.last?.arguments == [
            "chat-background", "status", "--chat-id", "9", "--json",
        ])

        #expect(!service.call(
            name: "lookup_handle",
            arguments: ["address": "person@example.com"]
        ).isError)
        #expect(runner.calls.suffix(2).map(\.arguments) == [
            ["whois", "--address", "person@example.com", "--local", "--json"],
            ["nickname", "--address", "person@example.com", "--local", "--json"],
        ])
    }

    @Test("send keeps untrusted text in one process argument")
    func sendsWithoutInterpolation() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let service = env.service(runner: runner)
        let text = "\"; do shell script \"touch /tmp/nope\"; --"

        let result = service.call(name: "send_message", arguments: [
            "to": "+441234567890",
            "text": text,
            "service": "imessage",
        ])

        #expect(!result.isError)
        #expect(runner.calls.last?.arguments == ["rpc", "send"])
        #expect(runner.lastRPCParams["text"] as? String == text)
        #expect(runner.lastRPCParams["to"] as? String == "+441234567890")
        #expect(runner.lastRPCParams["transport"] as? String == "applescript")
    }

    @Test("no SMS fallback preserves the documented CLI routing flag")
    func sendWithoutSMSFallback() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let result = env.service(runner: runner).call(name: "send_message", arguments: [
            "to": "+441234567890",
            "text": "iMessage first",
            "no_sms_fallback": true,
        ])
        #expect(!result.isError)
        #expect(runner.calls.last?.arguments == [
            "send", "--to", "+441234567890", "--text", "iMessage first",
            "--service", "auto", "--no-sms-fallback", "--json",
        ])
    }

    @Test("writes disabled blocks send before imsg")
    func disabledWrites() throws {
        let env = try TestEnvironment()
        try env.settings.update { $0.writesEnabled = false }
        let runner = FakeRunner()
        let result = env.service(runner: runner).call(
            name: "send_message",
            arguments: ["to": "person@example.com", "text": "hello"]
        )
        #expect(result.isError)
        #expect(runner.calls.isEmpty)
    }

    @Test("denied approval blocks send")
    func deniedSend() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        runner.responses[["group", "--chat-id", "7", "--json"]] = CommandOutput(
            stdout: #"{"contact_name":"Test Person"}"# + "\n"
        )
        let result = env.service(runner: runner, approvals: AlwaysDeny()).call(
            name: "send_message",
            arguments: ["chat_id": 7, "text": "hello"]
        )
        #expect(result.isError)
        #expect(runner.calls == [
            FakeRunner.Call(arguments: ["group", "--chat-id", "7", "--json"])
        ])
        #expect(!runner.calls.contains { $0.arguments.first == "send" || $0.arguments.first == "rpc" })
    }

    @Test("requires exactly one send target")
    func sendTargetValidation() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let service = env.service(runner: runner)
        #expect(service.call(
            name: "send_message",
            arguments: ["chat_id": 1, "to": "+44123", "text": "hello"]
        ).isError)
        #expect(service.call(
            name: "send_message",
            arguments: ["text": "hello"]
        ).isError)
        #expect(runner.calls.isEmpty)
    }

    @Test("reaction freshness rejects a changed latest message")
    func reactionFreshness() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        runner.defaultResponse = CommandOutput(
            stdout: #"{"guid":"NEW","is_from_me":false,"created_at":"2026-07-24T10:00:00Z"}"# + "\n"
        )
        let result = env.service(runner: runner).call(name: "react_to_latest", arguments: [
            "chat_id": 4,
            "reaction": "like",
            "expected_message_guid": "OLD",
        ])
        #expect(result.isError)
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].arguments.first == "history")
    }

    @Test("reaction uses the honest most-recent command")
    func reaction() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let result = env.service(runner: runner).call(name: "react_to_latest", arguments: [
            "chat_id": 4,
            "reaction": "love",
        ])
        #expect(!result.isError)
        #expect(runner.calls.last?.arguments == [
            "react", "--chat-id", "4", "--reaction", "love", "--json",
        ])
    }

    @Test("live event cursors are monotonic")
    func eventCursor() throws {
        let env = try TestEnvironment()
        let first = env.events.append(payload: #"{"guid":"A"}"#)
        let second = env.events.append(payload: #"{"guid":"B"}"#)
        let cursor = LiveEventCursor(sessionID: env.events.sessionID, position: first.id)
        let result = env.service(runner: FakeRunner()).call(
            name: "get_new_messages",
            arguments: ["cursor": cursor.rawValue]
        )
        let structured = result.structuredContent?.value as? [String: Any]
        #expect(
            LiveEventCursor(rawValue: structured?["cursor"] as? String ?? "")?.position
                == second.id
        )
        #expect((structured?["events"] as? [Any])?.count == 1)
    }

    @Test("stale live cursor reports expiration")
    func expiredEventCursor() throws {
        let env = try TestEnvironment()
        let oldStore = EventStore()
        _ = oldStore.append(payload: #"{"guid":"OLD"}"#)
        let service = ToolService(
            runner: FakeRunner(),
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove()
        )

        let result = service.call(
            name: "get_new_messages",
            arguments: ["cursor": oldStore.latestCursor.rawValue]
        )
        let structured = result.structuredContent?.value as? [String: Any]

        #expect(!result.isError)
        #expect(structured?["status"] as? String == "cursor_expired")
        #expect(structured?["cursor_expired"] as? Bool == true)
        #expect((structured?["events"] as? [Any])?.isEmpty == true)
        #expect(
            LiveEventCursor(rawValue: structured?["cursor"] as? String ?? "")?.sessionID
                == env.events.sessionID
        )
    }

    @Test("bounded wait ignores unrelated, reaction, and outgoing events")
    func waitForIncomingMessage() throws {
        let env = try TestEnvironment()
        let service = ToolService(
            runner: FakeRunner(),
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove(),
            statusProvider: { ["live_events_running": true] }
        )
        let baseline = env.events.latestCursor.rawValue
        let result = LockedToolResult()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            result.set(service.call(name: "wait_for_message", arguments: [
                "chat_id": 42,
                "cursor": baseline,
                "timeout_seconds": 2,
            ]))
            finished.signal()
        }

        _ = env.events.append(payload: #"{"chat_id":7,"guid":"OTHER","is_from_me":false}"#)
        _ = env.events.append(payload: #"{"chat_id":42,"guid":"REACTION","is_reaction":true,"is_from_me":false}"#)
        _ = env.events.append(payload: #"{"chat_id":42,"guid":"OUT","is_from_me":true}"#)
        _ = env.events.append(payload: #"{"chat_id":42,"guid":"MATCH","is_from_me":false}"#)

        #expect(finished.wait(timeout: .now() + 1) == .success)
        let structured = result.value?.structuredContent?.value as? [String: Any]
        let event = structured?["event"] as? [String: Any]
        #expect(structured?["status"] as? String == "matched")
        #expect(event?["guid"] as? String == "MATCH")
        #expect(LiveEventCursor(rawValue: structured?["cursor"] as? String ?? "") != nil)
    }

    @Test("wait without cursor starts from call time")
    func waitFromNow() throws {
        let env = try TestEnvironment()
        _ = env.events.append(payload: #"{"chat_id":42,"guid":"OLD","is_from_me":false}"#)
        let service = ToolService(
            runner: FakeRunner(),
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove(),
            statusProvider: { ["live_events_running": true] }
        )
        let result = LockedToolResult()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            result.set(service.call(name: "wait_for_message", arguments: [
                "chat_id": 42,
                "timeout_seconds": 2,
            ]))
            finished.signal()
        }

        var completed = false
        for index in 1...10 {
            _ = env.events.append(
                payload: #"{"chat_id":42,"guid":"NEW-\#(index)","is_from_me":false}"#
            )
            if finished.wait(timeout: .now() + 0.1) == .success {
                completed = true
                break
            }
        }

        #expect(completed)
        let structured = result.value?.structuredContent?.value as? [String: Any]
        let event = structured?["event"] as? [String: Any]
        #expect(structured?["status"] as? String == "matched")
        #expect(event?["guid"] as? String != "OLD")
        #expect((event?["guid"] as? String)?.hasPrefix("NEW-") == true)
    }

    @Test("matched wait cursor preserves later buffered events")
    func waitCursorStopsAtMatch() throws {
        let env = try TestEnvironment()
        let baseline = env.events.latestCursor.rawValue
        _ = env.events.append(payload: #"{"chat_id":42,"guid":"MATCH","is_from_me":false}"#)
        let later = env.events.append(
            payload: #"{"chat_id":42,"guid":"LATER","is_from_me":false}"#
        )
        let service = ToolService(
            runner: FakeRunner(),
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove(),
            statusProvider: { ["live_events_running": true] }
        )

        let waited = service.call(name: "wait_for_message", arguments: [
            "chat_id": 42,
            "cursor": baseline,
            "timeout_seconds": 1,
        ])
        let waitedValue = waited.structuredContent?.value as? [String: Any]
        let matchedCursor = waitedValue?["cursor"] as? String
        let remaining = service.call(name: "get_new_messages", arguments: [
            "cursor": matchedCursor ?? "",
        ])
        let remainingValue = remaining.structuredContent?.value as? [String: Any]
        let remainingEvents = remainingValue?["events"] as? [[String: Any]]

        #expect(waitedValue?["status"] as? String == "matched")
        #expect(
            LiveEventCursor(rawValue: matchedCursor ?? "")?.position
                == later.id - 1
        )
        #expect(remainingEvents?.first?["guid"] as? String == "LATER")
    }

    @Test("wait fails fast when watcher is unavailable")
    func watcherUnavailable() throws {
        let env = try TestEnvironment()
        let result = env.service(runner: FakeRunner()).call(
            name: "wait_for_message",
            arguments: ["chat_id": 42, "timeout_seconds": 90]
        )
        let structured = result.structuredContent?.value as? [String: Any]

        #expect(!result.isError)
        #expect(structured?["status"] as? String == "watcher_unavailable")
    }

    @Test("attachment reader rejects unrelated local files")
    func attachmentScope() throws {
        let env = try TestEnvironment()
        let result = env.service(runner: FakeRunner()).call(
            name: "read_attachment",
            arguments: ["path": "/etc/hosts"]
        )
        #expect(result.isError)
    }
}
