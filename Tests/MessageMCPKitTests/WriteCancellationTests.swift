import Foundation
import Testing
@testable import MessageMCPKit

private final class LockedToolResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ToolCallResult?

    var value: ToolCallResult? { lock.withLock { storage } }
    func set(_ value: ToolCallResult) { lock.withLock { storage = value } }
}

@Suite("Mutating request cancellation")
struct WriteCancellationTests {
    @Test("a cancellation after approval prevents the send")
    func cancellationRevokesLaterSendApproval() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let cancellation = ToolCallCancellation()
        let approval = RecordingApproval(approved: true) {
            cancellation.cancel()
        }

        let result = env.service(runner: runner, approvals: approval).call(
            name: "send_message",
            arguments: ["to": "+441234567890", "text": "do not send"],
            context: ToolCallContext(cancellation: cancellation)
        )

        #expect(result.isError)
        #expect(runner.calls.isEmpty)
    }

    @Test("a cancellation after approval prevents the tapback")
    func cancellationRevokesLaterReactionApproval() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        runner.responses[[
            "history", "--chat-id", "4", "--limit", "20", "--json",
        ]] = CommandOutput(
            stdout: #"[{"guid":"EXPECTED","is_from_me":false,"created_at":"2026-07-24T10:00:00Z"}]"# + "\n"
        )
        let cancellation = ToolCallCancellation()
        let approval = RecordingApproval(approved: true) {
            cancellation.cancel()
        }

        let result = env.service(runner: runner, approvals: approval).call(
            name: "react_to_latest",
            arguments: [
                "chat_id": 4,
                "reaction": "like",
                "expected_message_guid": "EXPECTED",
            ],
            context: ToolCallContext(cancellation: cancellation)
        )

        #expect(result.isError)
        #expect(runner.calls.filter { $0.arguments.first == "history" }.count == 1)
        #expect(!runner.calls.contains { $0.arguments.first == "react" })
    }

    @Test("Approve All / Allow Without Asking keeps cancellation enforcement")
    func approveAllCancellation() throws {
        let env = try TestEnvironment()
        try env.settings.update {
            $0.confirmSends = false
            $0.confirmReactions = false
        }
        let runner = FakeRunner()
        let approval = RecordingApproval(approved: true)
        let cancellation = ToolCallCancellation()
        cancellation.cancel()

        let result = env.service(runner: runner, approvals: approval).call(
            name: "send_message",
            arguments: ["to": "+441234567890", "text": "do not send"],
            context: ToolCallContext(cancellation: cancellation)
        )

        #expect(result.isError)
        #expect(approval.requests.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("wait_for_message wakes promptly when its request is cancelled")
    func waitCancellation() throws {
        let env = try TestEnvironment()
        makeWatcherAvailable(env.events)
        let cancellation = ToolCallCancellation()
        let result = LockedToolResult()
        let finished = DispatchSemaphore(value: 0)
        let service = ToolService(
            runner: FakeRunner(),
            settings: env.settings,
            activity: env.activity,
            events: env.events,
            approvals: AlwaysApprove(),
            outboundAttachmentStaging: env.directory.appendingPathComponent("staging"),
            statusProvider: { ["live_events_running": true] }
        )
        let cursor = env.events.latestCursor.rawValue

        DispatchQueue.global().async {
            result.set(service.call(
                name: "wait_for_message",
                arguments: [
                    "chat_id": 4,
                    "cursor": cursor,
                    "timeout_seconds": 90,
                ],
                context: ToolCallContext(cancellation: cancellation)
            ))
            finished.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        cancellation.cancel()

        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(result.value?.isError == true)
    }
}
