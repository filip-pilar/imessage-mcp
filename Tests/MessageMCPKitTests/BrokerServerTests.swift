import Darwin
import Foundation
import Testing
@testable import MessageMCPKit

private final class LineInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var lines: [Data] = []

    func append(_ line: Data) {
        lock.withLock { lines.append(line) }
        semaphore.signal()
    }

    func next(timeout: TimeInterval = 2) throws -> [String: Any] {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw UnixSocketError.disconnected
        }
        let data = lock.withLock { lines.removeFirst() }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

private final class ClientStatusInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var snapshots: [[MCPClientStatus]] = []

    func append(_ statuses: [MCPClientStatus]) {
        lock.withLock { snapshots.append(statuses) }
        semaphore.signal()
    }

    func waitForClient(named name: String, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard semaphore.wait(timeout: .now() + remaining) == .success else { return false }
            let statuses = lock.withLock { snapshots.removeFirst() }
            if statuses.contains(where: { $0.name == name && $0.initialized }) {
                return true
            }
        }
        return false
    }
}

private final class BlockingAttachmentRunner: IMsgRunning, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stagedPathStorage: String?

    var stagedPath: String? { lock.withLock { stagedPathStorage } }

    func run(arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        CommandOutput(stdout: #"{"ok":true}"# + "\n")
    }

    func rpc(method: String, params: [String: Any], timeout: TimeInterval) throws -> Any {
        lock.withLock { stagedPathStorage = params["file"] as? String }
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
        return ["ok": true]
    }
}

private final class LockedDrainResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    var value: Bool? { lock.withLock { storage } }
    func set(_ value: Bool) { lock.withLock { storage = value } }
}

@Suite("Authenticated MCP broker")
struct BrokerServerTests {
    @Test("authenticates, serves MCP, and pushes subscribed events")
    func endToEnd() throws {
        let env = try TestEnvironment()
        let service = env.service(runner: FakeRunner())
        let processor = MCPProcessor(tools: service) { ["ready": true] }
        let path = "/tmp/imessage-mcp-broker-\(UUID().uuidString.prefix(8)).sock"
        let broker = BrokerServer(socketPath: path, token: "secret", processor: processor)
        let clientStatuses = ClientStatusInbox()
        broker.onClientsChanged = { clientStatuses.append($0) }
        try broker.start()
        defer { broker.stop() }

        let client = try UnixSocketClient.connect(path: path)
        let inbox = LineInbox()
        DispatchQueue.global().async {
            try? client.readLines {
                inbox.append($0)
                return true
            }
        }

        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "type": "hello", "token": "secret",
        ]))
        #expect(try inbox.next()["ok"] as? Bool == true)

        try client.writeLine(try mcpRequest(method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "clientInfo": ["name": "integration-test", "version": "1"],
        ]))
        let initialize = try inbox.next()
        #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        #expect(clientStatuses.waitForClient(named: "integration-test"))

        try client.writeLine(try mcpRequest(id: 2, method: "tools/list"))
        let listed = try inbox.next()
        let tools = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        #expect(tools.contains { $0["name"] as? String == "send_message" })
        #expect(tools.contains { $0["name"] as? String == "get_new_messages" })
        #expect(tools.contains { $0["name"] as? String == "wait_for_message" })

        try client.writeLine(try mcpRequest(id: 3, method: "resources/subscribe", params: [
            "uri": MCPProcessor.eventsURI,
        ]))
        #expect(try inbox.next()["id"] as? Int == 3)

        _ = env.events.append(payload: #"{"guid":"LIVE"}"#)
        broker.notifyEvent()
        let notification = try inbox.next()
        #expect(notification["method"] as? String == "notifications/resources/updated")
        #expect((notification["params"] as? [String: Any])?["uri"] as? String == MCPProcessor.eventsURI)
    }

    @Test("rejects an incorrect broker token")
    func rejectsBadToken() throws {
        let env = try TestEnvironment()
        let processor = MCPProcessor(tools: env.service(runner: FakeRunner())) { [:] }
        let path = "/tmp/imessage-mcp-auth-\(UUID().uuidString.prefix(8)).sock"
        let broker = BrokerServer(socketPath: path, token: "right", processor: processor)
        try broker.start()
        defer { broker.stop() }

        let client = try UnixSocketClient.connect(path: path)
        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "type": "hello", "token": "wrong",
        ]))
        var response: [String: Any] = [:]
        try client.readLines {
            response = (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) ?? [:]
            return false
        }
        #expect(response["ok"] as? Bool == false)
    }

    @Test("disconnects a subscribed peer that stops reading")
    func disconnectsStalledSubscriber() throws {
        let env = try TestEnvironment()
        let processor = MCPProcessor(tools: env.service(runner: FakeRunner())) { [:] }
        let path = "/tmp/imessage-mcp-stalled-\(UUID().uuidString.prefix(8)).sock"
        let broker = BrokerServer(socketPath: path, token: "secret", processor: processor)
        try broker.start()
        defer { broker.stop() }

        let client = try UnixSocketClient.connect(path: path)
        var receiveBuffer: Int32 = 1_024
        #expect(Darwin.setsockopt(
            client.fd,
            SOL_SOCKET,
            SO_RCVBUF,
            &receiveBuffer,
            socklen_t(MemoryLayout.size(ofValue: receiveBuffer))
        ) == 0)

        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "type": "hello", "token": "secret",
        ]))
        #expect(try readOneJSON(from: client)["ok"] as? Bool == true)

        try client.writeLine(try mcpRequest(id: 1, method: "resources/subscribe", params: [
            "uri": MCPProcessor.eventsURI,
        ]))
        #expect(try readOneJSON(from: client)["id"] as? Int == 1)
        #expect(broker.clientCount == 1)

        let started = Date()
        for _ in 0..<100_000 where broker.clientCount > 0 {
            broker.notifyEvent()
        }

        #expect(broker.clientCount == 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("reads cancellation while a write approval is pending")
    func cancellationDuringApproval() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let approvals = ApprovalCenter()
        let approvalAppeared = DispatchSemaphore(value: 0)
        approvals.onChange = { requests in
            if !requests.isEmpty { approvalAppeared.signal() }
        }
        let processor = MCPProcessor(
            tools: env.service(runner: runner, approvals: approvals)
        ) { [:] }
        let path = "/tmp/imessage-mcp-cancel-\(UUID().uuidString.prefix(8)).sock"
        let broker = BrokerServer(socketPath: path, token: "secret", processor: processor)
        try broker.start()
        defer { broker.stop() }

        let client = try UnixSocketClient.connect(path: path)
        let inbox = LineInbox()
        DispatchQueue.global().async {
            try? client.readLines {
                inbox.append($0)
                return true
            }
        }
        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "type": "hello", "token": "secret",
        ]))
        #expect(try inbox.next()["ok"] as? Bool == true)

        try client.writeLine(try mcpRequest(id: 41, method: "tools/call", params: [
            "name": "send_message",
            "arguments": ["to": "+441234567890", "text": "do not send"],
        ]))
        #expect(approvalAppeared.wait(timeout: .now() + 1) == .success)
        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 41],
        ]))

        let response = try inbox.next()
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(runner.calls.isEmpty)
        #expect(approvals.requests.isEmpty)
    }

    @Test("a client half-close cancels a pending write and drains its error response")
    func halfCloseDuringApproval() throws {
        let env = try TestEnvironment()
        let runner = FakeRunner()
        let approvals = ApprovalCenter()
        let approvalAppeared = DispatchSemaphore(value: 0)
        approvals.onChange = { requests in
            if !requests.isEmpty { approvalAppeared.signal() }
        }
        let processor = MCPProcessor(
            tools: env.service(runner: runner, approvals: approvals)
        ) { [:] }
        let path = "/tmp/imessage-mcp-half-close-\(UUID().uuidString.prefix(8)).sock"
        let broker = BrokerServer(socketPath: path, token: "secret", processor: processor)
        try broker.start()
        defer { broker.stop() }

        let client = try UnixSocketClient.connect(path: path)
        let inbox = LineInbox()
        DispatchQueue.global().async {
            try? client.readLines {
                inbox.append($0)
                return true
            }
        }
        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "type": "hello", "token": "secret",
        ]))
        #expect(try inbox.next()["ok"] as? Bool == true)
        try client.writeLine(try mcpRequest(id: 42, method: "tools/call", params: [
            "name": "send_message",
            "arguments": ["to": "+441234567890", "text": "do not send"],
        ]))
        #expect(approvalAppeared.wait(timeout: .now() + 1) == .success)

        client.finishWriting()

        let response = try inbox.next()
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(runner.calls.isEmpty)
        #expect(approvals.requests.isEmpty)
    }

    @Test("global in-flight capacity returns overload while another write is pending")
    func globalBackpressure() throws {
        let env = try TestEnvironment()
        let approvals = ApprovalCenter()
        let approvalAppeared = DispatchSemaphore(value: 0)
        approvals.onChange = { requests in
            if !requests.isEmpty { approvalAppeared.signal() }
        }
        let processor = MCPProcessor(
            tools: env.service(runner: FakeRunner(), approvals: approvals)
        ) { [:] }
        let path = "/tmp/imessage-mcp-overload-\(UUID().uuidString.prefix(8)).sock"
        let broker = BrokerServer(
            socketPath: path,
            token: "secret",
            processor: processor,
            maximumInFlightToolCalls: 1
        )
        try broker.start()
        defer { broker.stop() }

        let client = try UnixSocketClient.connect(path: path)
        let inbox = LineInbox()
        DispatchQueue.global().async {
            try? client.readLines {
                inbox.append($0)
                return true
            }
        }
        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "type": "hello", "token": "secret",
        ]))
        #expect(try inbox.next()["ok"] as? Bool == true)

        try client.writeLine(try mcpRequest(id: 51, method: "tools/call", params: [
            "name": "send_message",
            "arguments": ["to": "+441234567890", "text": "pending"],
        ]))
        #expect(approvalAppeared.wait(timeout: .now() + 1) == .success)
        try client.writeLine(try mcpRequest(id: 52, method: "tools/call", params: [
            "name": "list_chats",
            "arguments": [:],
        ]))

        let overloaded = try inbox.next()
        #expect(overloaded["id"] as? Int == 52)
        #expect(((overloaded["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue == -32001)

        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 51],
        ]))
        let cancelled = try inbox.next()
        #expect(cancelled["id"] as? Int == 51)
        #expect(((cancelled["result"] as? [String: Any])?["isError"] as? Bool) == true)
    }

    @Test("graceful stop drains accepted attachment workers before returning")
    func stopDrainsAttachmentWorker() throws {
        let env = try TestEnvironment()
        try env.settings.update { $0.confirmSends = false }
        let attachment = env.directory.appendingPathComponent("payload.txt")
        try Data("private attachment bytes".utf8).write(to: attachment)
        let runner = BlockingAttachmentRunner()
        let processor = MCPProcessor(tools: env.service(runner: runner)) { [:] }
        let path = "/tmp/imessage-mcp-drain-\(UUID().uuidString.prefix(8)).sock"
        let broker = BrokerServer(socketPath: path, token: "secret", processor: processor)
        try broker.start()

        let client = try UnixSocketClient.connect(path: path)
        try client.writeLine(try JSONSerialization.data(withJSONObject: [
            "type": "hello", "token": "secret",
        ]))
        #expect(try readOneJSON(from: client)["ok"] as? Bool == true)
        try client.writeLine(try mcpRequest(id: 61, method: "tools/call", params: [
            "name": "send_message",
            "arguments": [
                "to": "+441234567890",
                "file": attachment.path,
            ],
        ]))
        #expect(runner.entered.wait(timeout: .now() + 1) == .success)
        let stagedPath = try #require(runner.stagedPath)
        #expect(FileManager.default.fileExists(atPath: stagedPath))

        let drained = LockedDrainResult()
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            drained.set(broker.stopAndDrain(timeout: 2))
            stopped.signal()
        }
        #expect(stopped.wait(timeout: .now() + 0.05) == .timedOut)
        runner.release.signal()

        #expect(stopped.wait(timeout: .now() + 1) == .success)
        #expect(drained.value == true)
        #expect(!FileManager.default.fileExists(atPath: stagedPath))
        #expect(!FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: stagedPath).deletingLastPathComponent().path
        ))
    }

    private func readOneJSON(from connection: SocketLineConnection) throws -> [String: Any] {
        var value: [String: Any] = [:]
        try connection.readLines { line in
            value = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            return false
        }
        return value
    }
}
