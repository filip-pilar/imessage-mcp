import Foundation
@testable import MessageMCPKit

final class FakeRunner: IMsgRunning, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
    }

    private let lock = NSLock()
    private var storage: [Call] = []
    private var rpcParamsStorage: [String: Any] = [:]
    var responses: [[String]: CommandOutput] = [:]
    var defaultResponse = CommandOutput(stdout: #"{"ok":true}"# + "\n")
    var rpcResponse: Any = ["ok": true]

    var calls: [Call] { lock.withLock { storage } }
    var lastRPCParams: [String: Any] { lock.withLock { rpcParamsStorage } }

    func run(arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        lock.withLock { storage.append(Call(arguments: arguments)) }
        return responses[arguments] ?? defaultResponse
    }

    func rpc(method: String, params: [String: Any], timeout: TimeInterval) throws -> Any {
        lock.withLock {
            storage.append(Call(arguments: ["rpc", method]))
            rpcParamsStorage = params
        }
        return rpcResponse
    }
}

struct TestEnvironment {
    let directory: URL
    let settings: SettingsStore
    let activity: ActivityStore
    let events: EventStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        activity = ActivityStore(url: directory.appendingPathComponent("activity.json"))
        events = EventStore()
    }

    func service(runner: IMsgRunning, approvals: ApprovalProviding = AlwaysApprove()) -> ToolService {
        ToolService(
            runner: runner,
            settings: settings,
            activity: activity,
            events: events,
            approvals: approvals
        )
    }
}

func decodeJSON(_ data: Data?) throws -> [String: Any] {
    guard let data else { return [:] }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

func mcpRequest(id: Int = 1, method: String, params: [String: Any] = [:]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    ])
}
