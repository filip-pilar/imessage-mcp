import Darwin
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
        let liveDescription = ToolService.tools.first {
            $0.name == "get_new_messages"
        }?.description
        #expect(liveDescription?.contains("watcher restart") == true)
        #expect(liveDescription?.contains("continuity break") == true)
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

    @Test("mutating tools reject unknown, coercive, and ambiguous arguments")
    func strictWriteArguments() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let approval = RecordingApproval(approved: true)
        let service = env.service(runner: runner, approvals: approval)
        let invalidSends: [[String: Any]] = [
            ["to": "+441234567890", "text": "hello", "unknown": true],
            ["to": "+441234567890", "text": "hello", "no_sms_fallback": "true"],
            ["to": "+441234567890", "text": "hello", "no_sms_fallback": 1],
            ["to": "+441234567890", "text": "hello", "service": "sms", "no_sms_fallback": true],
            ["chat_id": true, "text": "hello"],
            ["chat_id": 4.5, "text": "hello"],
            ["chat_id": "4", "text": "hello"],
            ["to": "Test Person", "text": "hello"],
            ["to": "0501234567", "text": "hello"],
            ["to": "+441234567890", "text": 42],
            ["to": "+441234567890", "text": "hello", "region": "GB"],
        ]
        for arguments in invalidSends {
            #expect(service.call(name: "send_message", arguments: arguments).isError)
        }

        let invalidReactions: [[String: Any]] = [
            ["chat_id": 4, "reaction": "like", "expected_message_guid": "GUID", "extra": 1],
            ["chat_id": true, "reaction": "like", "expected_message_guid": "GUID"],
            ["chat_id": 4.5, "reaction": "like", "expected_message_guid": "GUID"],
            ["chat_id": "4", "reaction": "like", "expected_message_guid": "GUID"],
            ["chat_id": 4, "reaction": "like"],
            ["chat_id": 4, "reaction": true, "expected_message_guid": "GUID"],
        ]
        for arguments in invalidReactions {
            #expect(service.call(name: "react_to_latest", arguments: arguments).isError)
        }

        #expect(runner.calls.isEmpty)
        #expect(approval.requests.isEmpty)
    }

    @Test("send approval contains the complete normalized intent")
    func completeSendApproval() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("payload.txt")
        try Data("attachment".utf8).write(to: attachment)
        let text = String(repeating: "full-payload-", count: 20) + "END"
        let approval = RecordingApproval(approved: false)
        let runner = FakeRunner()
        let result = env.service(runner: runner, approvals: approval).call(
            name: "send_message",
            arguments: [
                "to": "Person@EXAMPLE.COM",
                "text": text,
                "file": attachment.path,
                "service": "imessage",
                "no_sms_fallback": true,
            ]
        )

        #expect(result.isError)
        let request = try #require(approval.requests.first)
        #expect(request.title.contains("Person@example.com"))
        #expect(request.detail.contains("Target: \"Person@example.com\""))
        #expect(request.detail.contains("Service: imessage"))
        #expect(request.detail.contains("SMS fallback: blocked"))
        #expect(request.detail.contains(text))
        #expect(request.detail.contains("END"))
        let canonicalAttachment = try SecureFileIO.canonicalExistingURL(attachment)
        #expect(request.detail.contains("Attachment: \"\(canonicalAttachment.path)\""))
        #expect(request.detail.contains("Attachment type:"))
        #expect(request.detail.contains("Attachment size: 10 bytes"))
        #expect(runner.calls.isEmpty)
    }

    @Test("approval rendering cannot turn message text into fake intent fields")
    func approvalDetailEscaping() throws {
        let env = try TestEnvironment()
        let approval = RecordingApproval(approved: false)
        let spoofedText =
            "hello\nAttachment: /tmp/not-approved\nTarget: +15550000000\u{2028}\u{202E}"
        let result = env.service(
            runner: FakeRunner(),
            approvals: approval
        ).call(
            name: "send_message",
            arguments: [
                "to": "+441234567890",
                "text": spoofedText,
            ]
        )

        #expect(result.isError)
        let detail = try #require(approval.requests.first?.detail)
        #expect(detail.components(separatedBy: "\nAttachment:").count == 2)
        #expect(detail.contains("\\nAttachment: /tmp/not-approved"))
        #expect(detail.contains("\\nTarget: +15550000000"))
        #expect(detail.contains("\\u{2028}"))
        #expect(detail.contains("\\u{202E}"))
        #expect(!detail.contains("\nTarget: +15550000000"))
    }

    @Test("tapback approval rendering cannot spoof intent fields")
    func reactionApprovalDetailEscaping() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        runner.responses[["history", "--chat-id", "4", "--limit", "20", "--json"]] =
            CommandOutput(
                stdout: #"[{"guid":"EXPECTED","is_from_me":false,"created_at":"2026-07-24T10:00:00Z"}]"#
                    + "\n"
            )
        runner.responses[["group", "--chat-id", "4", "--json"]] = CommandOutput(
            stdout: #"{"display_name":"Friends\nReaction: dislike\u2028Target: chat_id 9"}"# + "\n"
        )
        let approval = RecordingApproval(approved: false)
        let result = env.service(runner: runner, approvals: approval).call(
            name: "react_to_latest",
            arguments: [
                "chat_id": 4,
                "reaction": "like",
                "expected_message_guid": "EXPECTED",
            ]
        )

        #expect(result.isError)
        let detail = try #require(approval.requests.first?.detail)
        #expect(detail.contains("Friends\\nReaction: dislike\\u{2028}Target: chat_id 9"))
        #expect(detail.contains("Expected message GUID: \"EXPECTED\""))
        #expect(detail.components(separatedBy: "\nReaction:").count == 2)
        #expect(!detail.contains("\nTarget: chat_id 9"))
        #expect(!runner.calls.contains { $0.arguments.first == "react" })
    }

    @Test("entering Read Only revokes a pending send even if writes are re-enabled")
    func sendPolicyRecheck() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let approval = RecordingApproval(approved: true) {
            try! env.settings.update { $0.writesEnabled = false }
            try! env.settings.update { $0.writesEnabled = true }
        }
        let result = env.service(runner: runner, approvals: approval).call(
            name: "send_message",
            arguments: ["to": "+441234567890", "text": "do not send"]
        )

        #expect(result.isError)
        #expect(runner.calls.isEmpty)
    }

    @Test("entering Read Only revokes a pending tapback even if writes are re-enabled")
    func reactionPolicyRecheck() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        runner.responses[[
            "history", "--chat-id", "4", "--limit", "20", "--json",
        ]] = CommandOutput(
            stdout: #"[{"guid":"EXPECTED","is_from_me":false,"created_at":"2026-07-24T10:00:00Z"}]"# + "\n"
        )
        let approval = RecordingApproval(approved: true) {
            try! env.settings.update { $0.writesEnabled = false }
            try! env.settings.update { $0.writesEnabled = true }
        }

        let result = env.service(runner: runner, approvals: approval).call(
            name: "react_to_latest",
            arguments: [
                "chat_id": 4,
                "reaction": "like",
                "expected_message_guid": "EXPECTED",
            ]
        )

        #expect(result.isError)
        #expect(!runner.calls.contains { $0.arguments.first == "react" })
    }

    @Test("send uses the approved staged bytes after equal-size source replacement")
    func attachmentBytesAreStableAfterApproval() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("payload.txt")
        try Data("first".utf8).write(to: attachment)
        let runner = FakeRunner()
        let approval = RecordingApproval(approved: true) {
            try! Data("other".utf8).write(to: attachment)
        }
        let result = env.service(runner: runner, approvals: approval).call(
            name: "send_message",
            arguments: [
                "to": "+441234567890",
                "text": "hello",
                "file": attachment.path,
            ]
        )

        #expect(!result.isError)
        #expect(runner.lastRPCFileData == Data("first".utf8))
        #expect(try Data(contentsOf: attachment) == Data("other".utf8))
    }

    @Test("send resolves source symlinks and executes from a private staged copy")
    func stagedAttachmentPath() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("payload.txt")
        let symlink = env.directory.appendingPathComponent("payload-link.txt")
        try Data("attachment".utf8).write(to: attachment)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: attachment
        )
        let runner = FakeRunner()
        let result = env.service(runner: runner).call(
            name: "send_message",
            arguments: [
                "to": "+441234567890",
                "text": "hello",
                "file": symlink.path,
            ]
        )

        #expect(!result.isError)
        let sentPath = try #require(runner.lastRPCParams["file"] as? String)
        #expect(sentPath != attachment.path)
        #expect(sentPath.contains("outbound-attachments"))
        #expect(URL(fileURLWithPath: sentPath).lastPathComponent == attachment.lastPathComponent)
        #expect(runner.lastRPCFileData == Data("attachment".utf8))
        #expect(!FileManager.default.fileExists(atPath: sentPath))
        #expect(!FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: sentPath).deletingLastPathComponent().path
        ))
    }

    @Test("outbound staging rejects growth after its initial descriptor check")
    func stagedAttachmentCopyIsBounded() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("payload.txt")
        try Data("tiny".utf8).write(to: attachment)
        let service = env.service(runner: FakeRunner())

        #expect(throws: ToolServiceError.self) {
            try service.canonicalOutboundAttachment(
                at: attachment.path,
                maximumBytes: 4
            ) {
                let handle = try FileHandle(forWritingTo: attachment)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("growth".utf8))
            }
        }
    }

    @Test("outbound staging refuses a symlinked private-copy directory")
    func stagedAttachmentDirectoryRejectsSymlink() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("payload.txt")
        try Data("attachment".utf8).write(to: attachment)
        let outside = env.directory.appendingPathComponent("outside", isDirectory: true)
        let stagingLink = env.directory.appendingPathComponent("staging-link", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: stagingLink,
            withDestinationURL: outside
        )
        let runner = FakeRunner()
        let service = ToolService(
            runner: runner,
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove(),
            outboundAttachmentStaging: stagingLink
        )

        let result = service.call(
            name: "send_message",
            arguments: [
                "to": "+441234567890",
                "file": attachment.path,
            ]
        )

        #expect(result.isError)
        #expect(runner.calls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Read Only and pre-cancelled sends do not create attachment staging")
    func policyAndCancellationPrecedeStaging() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("payload.txt")
        try Data("attachment".utf8).write(to: attachment)
        let staging = env.directory.appendingPathComponent("outbound-attachments")
        let service = env.service(runner: FakeRunner())

        try env.settings.update { $0.writesEnabled = false }
        let readOnly = service.call(
            name: "send_message",
            arguments: ["to": "+441234567890", "file": attachment.path]
        )
        #expect(readOnly.isError)
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        try env.settings.update { $0.writesEnabled = true }
        let cancellation = ToolCallCancellation()
        cancellation.cancel()
        let cancelled = service.call(
            name: "send_message",
            arguments: ["to": "+441234567890", "file": attachment.path],
            context: ToolCallContext(cancellation: cancellation)
        )
        #expect(cancelled.isError)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("attachment copy observes cancellation and removes its partial stage")
    func attachmentCopyCancellation() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("large.bin")
        try Data(repeating: 0x41, count: 256 * 1_024).write(to: attachment)
        let service = env.service(runner: FakeRunner())
        let cancellation = ToolCallCancellation()

        #expect(throws: ToolServiceError.self) {
            try service.canonicalOutboundAttachment(
                at: attachment.path,
                maximumBytes: 512 * 1_024,
                cancellation: cancellation,
                didCopyChunk: { cancellation.cancel() }
            )
        }

        let staging = env.directory.appendingPathComponent("outbound-attachments")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty
        )
        #expect(!service.attachmentCleanupPending)
    }

    @Test("startup sweep removes abandoned private attachment bytes")
    func abandonedAttachmentStartupSweep() throws {
        let env = try TestEnvironment()
        let staging = env.directory.appendingPathComponent("outbound-attachments")
        let abandoned = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = abandoned.appendingPathComponent("private.txt")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("private attachment bytes".utf8).write(to: payload)
        let service = env.service(runner: FakeRunner())

        try service.prepareAttachmentStaging()

        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(!service.attachmentCleanupPending)
    }

    @Test("startup sweep never follows a staging-root symlink")
    func abandonedAttachmentSweepContainment() throws {
        let env = try TestEnvironment()
        let outside = env.directory.appendingPathComponent("outside", isDirectory: true)
        let abandoned = outside.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = abandoned.appendingPathComponent("keep.txt")
        let stagingLink = env.directory.appendingPathComponent("staging-link", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("must remain".utf8).write(to: payload)
        try FileManager.default.createSymbolicLink(
            at: stagingLink,
            withDestinationURL: outside
        )
        let service = ToolService(
            runner: FakeRunner(),
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove(),
            outboundAttachmentStaging: stagingLink
        )

        #expect(throws: ToolServiceError.self) {
            try service.prepareAttachmentStaging()
        }
        #expect(try Data(contentsOf: payload) == Data("must remain".utf8))
        #expect(FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test("failed attachment cleanup is visible and retryable")
    func attachmentCleanupRetry() throws {
        let env = try TestEnvironment()
        let attachment = env.directory.appendingPathComponent("payload.txt")
        try Data("attachment".utf8).write(to: attachment)
        let runner = FakeRunner()
        runner.rpcWillReturn = { params in
            guard let path = params["file"] as? String else { return }
            _ = Darwin.chmod(
                URL(fileURLWithPath: path).deletingLastPathComponent().path,
                mode_t(0o500)
            )
        }
        let service = env.service(runner: runner)

        let result = service.call(
            name: "send_message",
            arguments: ["to": "+441234567890", "file": attachment.path]
        )
        let stagedPath = try #require(runner.lastRPCParams["file"] as? String)
        let stagedDirectory = URL(fileURLWithPath: stagedPath).deletingLastPathComponent()

        #expect(!result.isError)
        #expect(service.attachmentCleanupPending)
        #expect(env.activity.recent.first?.kind == .error)
        #expect(FileManager.default.fileExists(atPath: stagedPath))

        #expect(Darwin.chmod(stagedDirectory.path, mode_t(0o700)) == 0)
        try service.prepareAttachmentStaging()
        #expect(!service.attachmentCleanupPending)
        #expect(!FileManager.default.fileExists(atPath: stagedPath))
        #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
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

    @Test("reaction target is rechecked immediately after approval")
    func reactionFreshnessAfterApproval() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let historyArguments = [
            "history", "--chat-id", "4", "--limit", "20", "--json",
        ]
        runner.responseSequences[historyArguments] = [
            CommandOutput(
                stdout: #"[{"guid":"EXPECTED","is_from_me":false,"created_at":"2026-07-24T10:00:00Z"}]"# + "\n"
            ),
            CommandOutput(
                stdout: #"[{"guid":"NEW","is_from_me":false,"created_at":"2026-07-24T10:01:00Z"}]"# + "\n"
            ),
        ]
        let result = env.service(runner: runner).call(
            name: "react_to_latest",
            arguments: [
                "chat_id": 4,
                "reaction": "like",
                "expected_message_guid": "EXPECTED",
            ]
        )

        #expect(result.isError)
        #expect(runner.calls.filter { $0.arguments.first == "history" }.count == 2)
        #expect(!runner.calls.contains { $0.arguments.first == "react" })
    }

    @Test("Approve All / Allow Without Asking keeps the complete write integrity path")
    func approveAllIntegrity() throws {
        let env = try TestEnvironment()
        try env.settings.update {
            $0.confirmSends = false
            $0.confirmReactions = false
        }
        let runner = FakeRunner()
        let historyArguments = [
            "history", "--chat-id", "4", "--limit", "20", "--json",
        ]
        runner.responses[historyArguments] = CommandOutput(
            stdout: #"[{"guid":"EXPECTED","is_from_me":false,"created_at":"2026-07-24T10:00:00Z"}]"# + "\n"
        )
        let approval = RecordingApproval(approved: false)
        let service = env.service(runner: runner, approvals: approval)

        let invalid = service.call(
            name: "send_message",
            arguments: [
                "to": "+441234567890",
                "text": "invalid fallback",
                "no_sms_fallback": "false",
            ]
        )
        let sent = service.call(
            name: "send_message",
            arguments: ["to": "+441234567890", "text": "hello"]
        )
        let reacted = service.call(
            name: "react_to_latest",
            arguments: [
                "chat_id": 4,
                "reaction": "love",
                "expected_message_guid": "EXPECTED",
            ]
        )

        #expect(invalid.isError)
        #expect(!sent.isError)
        #expect(!reacted.isError)
        #expect(approval.requests.isEmpty)
        #expect(runner.calls.filter { $0.arguments.first == "history" }.count == 2)
        #expect(runner.calls.contains { $0.arguments.first == "react" })
    }

    @Test("reaction uses the honest most-recent command")
    func reaction() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        runner.responses[[
            "history", "--chat-id", "4", "--limit", "20", "--json",
        ]] = CommandOutput(
            stdout: #"[{"guid":"EXPECTED","is_from_me":false,"created_at":"2026-07-24T10:00:00Z"}]"# + "\n"
        )
        let result = env.service(runner: runner).call(name: "react_to_latest", arguments: [
            "chat_id": 4,
            "reaction": "love",
            "expected_message_guid": "EXPECTED",
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
        makeWatcherAvailable(env.events)
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
        makeWatcherAvailable(env.events)
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
        makeWatcherAvailable(env.events)
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

    @Test("watcher stop atomically expires an already-blocked message wait")
    func watcherStopExpiresBlockedWait() throws {
        let env = try TestEnvironment()
        let generation = makeWatcherAvailable(env.events)
        let cursor = env.events.watcherState.latestCursor.rawValue
        let enteredWait = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = LockedToolResult()
        env.events.waitWillBlock = { enteredWait.signal() }
        let service = env.service(runner: FakeRunner())

        DispatchQueue.global().async {
            result.set(service.call(
                name: "wait_for_message",
                arguments: [
                    "chat_id": 42,
                    "cursor": cursor,
                    "timeout_seconds": 90,
                ]
            ))
            finished.signal()
        }

        #expect(enteredWait.wait(timeout: .now() + 1) == .success)
        let stopped = try #require(env.events.endWatcherGeneration(generation))
        #expect(!stopped.isAvailable)
        #expect(finished.wait(timeout: .now() + 1) == .success)
        let structured = result.value?.structuredContent?.value as? [String: Any]
        #expect(structured?["status"] as? String == "cursor_expired")
        #expect(structured?["cursor"] as? String == stopped.latestCursor.rawValue)
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
