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
}
