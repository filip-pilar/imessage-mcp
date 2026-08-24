import Foundation
import Testing
@testable import MessageMCPKit

@Suite("MCP protocol")
struct MCPProcessorTests {
    func processor() throws -> MCPProcessor {
        let env = try TestEnvironment()
        return MCPProcessor(
            tools: env.service(runner: FakeRunner()),
            statusProvider: { ["ready": true] }
        )
    }

    @Test("negotiates lifecycle and advertises capabilities")
    func initialize() throws {
        let processor = try processor()
        let session = MCPConnectionSession()
        let response = try decodeJSON(processor.process(
            line: mcpRequest(method: "initialize", params: [
                "protocolVersion": "2025-11-25",
                "clientInfo": ["name": "tests", "version": "1"],
                "capabilities": [:],
            ]),
            session: session
        ))
        let result = response["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-11-25")
        #expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(session.initialized)
        #expect(session.clientName == "tests")
    }

    @Test("lists tools and resources")
    func listsCapabilities() throws {
        let processor = try processor()
        let session = MCPConnectionSession()
        let toolsResponse = try decodeJSON(processor.process(
            line: mcpRequest(method: "tools/list"),
            session: session
        ))
        let tools = (toolsResponse["result"] as? [String: Any])?["tools"] as? [Any]
        #expect(tools?.count == ToolService.tools.count)

        let resourcesResponse = try decodeJSON(processor.process(
            line: mcpRequest(method: "resources/list"),
            session: session
        ))
        let resources = (resourcesResponse["result"] as? [String: Any])?["resources"] as? [Any]
        #expect(resources?.count == 2)
    }

    @Test("returns JSON-RPC errors for unknown methods")
    func unknownMethod() throws {
        let response = try decodeJSON(try processor().process(
            line: mcpRequest(method: "unknown/method"),
            session: MCPConnectionSession()
        ))
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32601)
    }

    @Test("resource subscriptions receive standard notification shape")
    func subscription() throws {
        let session = MCPConnectionSession()
        _ = try processor().process(
            line: mcpRequest(method: "resources/subscribe", params: ["uri": MCPProcessor.eventsURI]),
            session: session
        )
        #expect(session.isSubscribed(to: MCPProcessor.eventsURI))
        let notification = try decodeJSON(MCPProcessor.resourceUpdatedNotification(uri: MCPProcessor.eventsURI))
        #expect(notification["method"] as? String == "notifications/resources/updated")
    }

    @Test("cancellation notifications revoke only the matching request")
    func cancellationNotification() throws {
        let processor = try processor()
        let session = MCPConnectionSession()
        let cancelled = try #require(session.prepareRequest(id: 41))
        let untouched = try #require(session.prepareRequest(id: "other"))
        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 41, "reason": "no longer needed"],
        ])

        #expect(processor.process(line: notification, session: session) == nil)
        #expect(cancelled.isCancelled)
        #expect(!untouched.isCancelled)
    }

    @Test("closing a session cancels active and not-yet-started requests")
    func closedSessionCancellation() throws {
        let session = MCPConnectionSession()
        let active = try #require(session.prepareRequest(id: 1))

        session.cancelAllRequests()
        let queued = try #require(session.prepareRequest(id: 2))

        #expect(active.isCancelled)
        #expect(queued.isCancelled)
    }

    @Test("tool-call notifications and malformed calls cannot execute writes")
    func mutatingCallsRequireCorrelatableRequests() throws {
        let env = try TestEnvironment()
        try env.settings.update {
            $0.confirmSends = false
            $0.confirmReactions = false
        }
        let runner = FakeRunner()
        let processor = MCPProcessor(tools: env.service(runner: runner)) { [:] }
        let session = MCPConnectionSession()
        let base: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": [
                "name": "send_message",
                "arguments": ["to": "+441234567890", "text": "do not send"],
            ],
        ]
        var requests = [base]
        requests.append(base.merging(["id": NSNull()]) { _, replacement in replacement })
        requests.append(base.merging(["id": true]) { _, replacement in replacement })

        for request in requests {
            let line = try JSONSerialization.data(withJSONObject: request)
            if case .notAsynchronousToolCall = processor.prepareAsynchronousToolCall(
                line: line,
                session: session
            ) {
                // Expected.
            } else {
                Issue.record("Invalid tool calls must not enter asynchronous execution.")
            }
            let response = try decodeJSON(processor.process(line: line, session: session))
            #expect((response["error"] as? [String: Any]) != nil)
        }

        let malformed = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 77,
            "method": "tools/call",
            "params": ["arguments": [:]],
        ])
        if case .notAsynchronousToolCall = processor.prepareAsynchronousToolCall(
            line: malformed,
            session: session
        ) {
            // Expected.
        } else {
            Issue.record("Malformed tool calls must not enter asynchronous execution.")
        }
        _ = processor.process(line: malformed, session: session)
        #expect(session.cancellation(for: 77) == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test("duplicate outstanding request IDs are rejected without detaching the original")
    func duplicateOutstandingRequestID() throws {
        let processor = try processor()
        let session = MCPConnectionSession()
        let line = try mcpRequest(id: 91, method: "tools/call", params: [
            "name": "list_chats",
            "arguments": [:],
        ])

        guard case .accepted = processor.prepareAsynchronousToolCall(
            line: line,
            session: session
        ) else {
            Issue.record("The first request should be admitted.")
            return
        }
        let original = try #require(session.cancellation(for: 91))
        guard case .rejected(let responseData) = processor.prepareAsynchronousToolCall(
            line: line,
            session: session
        ) else {
            Issue.record("The duplicate request should be rejected.")
            return
        }
        let response = try decodeJSON(responseData)
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32600)
        #expect(session.cancellation(for: 91) === original)
        #expect(!original.isCancelled)

        _ = processor.process(line: line, session: session)
        #expect(session.cancellation(for: 91) == nil)
    }

    @Test("per-connection in-flight limit returns an explicit overload error")
    func perConnectionBackpressure() throws {
        let processor = try processor()
        let session = MCPConnectionSession(maximumInFlightRequests: 1)
        let first = try mcpRequest(id: 1, method: "tools/call", params: [
            "name": "list_chats",
            "arguments": [:],
        ])
        let second = try mcpRequest(id: 2, method: "tools/call", params: [
            "name": "list_chats",
            "arguments": [:],
        ])
        guard case .accepted = processor.prepareAsynchronousToolCall(
            line: first,
            session: session
        ) else {
            Issue.record("The first request should be admitted.")
            return
        }
        guard case .rejected(let responseData) = processor.prepareAsynchronousToolCall(
            line: second,
            session: session
        ) else {
            Issue.record("The second request should be overloaded.")
            return
        }
        let response = try decodeJSON(responseData)
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32001)
        session.cancelAllRequests()
    }

    @Test("asynchronous request ID remains owned until its response is written")
    func responseWriteRetainsRequestOwnership() throws {
        let processor = try processor()
        let session = MCPConnectionSession()
        let line = try mcpRequest(id: 77, method: "tools/call", params: [
            "name": "list_chats",
            "arguments": [:],
        ])
        guard case .accepted = processor.prepareAsynchronousToolCall(
            line: line,
            session: session
        ) else {
            Issue.record("The original request should be admitted.")
            return
        }

        _ = processor.process(
            line: line,
            session: session,
            finishRequestWhenComplete: false
        )
        #expect(session.cancellation(for: 77) != nil)
        guard case .rejected(let duplicateResponse) = processor.prepareAsynchronousToolCall(
            line: line,
            session: session
        ) else {
            Issue.record("The ID must remain unavailable until response delivery finishes.")
            return
        }
        let duplicate = try decodeJSON(duplicateResponse)
        #expect(((duplicate["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue == -32600)

        processor.finishAsynchronousToolCall(line: line, session: session)
        #expect(session.cancellation(for: 77) == nil)
        guard case .accepted = processor.prepareAsynchronousToolCall(
            line: line,
            session: session
        ) else {
            Issue.record("The ID should be reusable after the response write completes.")
            return
        }
        session.cancelAllRequests()
    }
}
