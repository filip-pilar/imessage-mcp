import Foundation
@testable import MessageMCPKit

struct AlwaysApprove: CancellationAwareApprovalProviding {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval,
        cancellation: ToolCallCancellation?
    ) -> Bool { true }
}

struct AlwaysDeny: CancellationAwareApprovalProviding {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval,
        cancellation: ToolCallCancellation?
    ) -> Bool { false }
}

final class FakeRunner: IMsgRunning, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
    }

    private let lock = NSLock()
    private var storage: [Call] = []
    private var rpcParamsStorage: [String: Any] = [:]
    private var rpcFileDataStorage: Data?
    var responses: [[String]: CommandOutput] = [:]
    var responseSequences: [[String]: [CommandOutput]] = [:]
    var defaultResponse = CommandOutput(stdout: #"{"ok":true}"# + "\n")
    var rpcResponse: Any = ["ok": true]
    var rpcWillReturn: (@Sendable ([String: Any]) -> Void)?

    var calls: [Call] { lock.withLock { storage } }
    var lastRPCParams: [String: Any] { lock.withLock { rpcParamsStorage } }
    var lastRPCFileData: Data? { lock.withLock { rpcFileDataStorage } }

    func run(arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        lock.withLock {
            storage.append(Call(arguments: arguments))
            if var sequence = responseSequences[arguments], !sequence.isEmpty {
                let response = sequence.removeFirst()
                responseSequences[arguments] = sequence
                return response
            }
            return responses[arguments] ?? defaultResponse
        }
    }

    func rpc(method: String, params: [String: Any], timeout: TimeInterval) throws -> Any {
        lock.withLock {
            storage.append(Call(arguments: ["rpc", method]))
            rpcParamsStorage = params
            if let path = params["file"] as? String {
                rpcFileDataStorage = try? Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        rpcWillReturn?(params)
        return rpcResponse
    }
}

final class RecordingApproval: CancellationAwareApprovalProviding, @unchecked Sendable {
    struct Request: Equatable {
        let kind: ApprovalKind
        let title: String
        let detail: String
    }

    private let lock = NSLock()
    private let approved: Bool
    private let onRequest: @Sendable () -> Void
    private var storage: [Request] = []

    init(approved: Bool, onRequest: @escaping @Sendable () -> Void = {}) {
        self.approved = approved
        self.onRequest = onRequest
    }

    var requests: [Request] { lock.withLock { storage } }

    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval,
        cancellation: ToolCallCancellation?
    ) -> Bool {
        lock.withLock {
            storage.append(Request(kind: kind, title: title, detail: detail))
        }
        onRequest()
        return approved
    }
}

struct TestEnvironment {
    let directory: URL
    let settings: SettingsStore
    let activity: ActivityStore
    let events: EventStore

    init() throws {
        directory = try SecureFileIO.canonicalExistingURL(
            FileManager.default.temporaryDirectory
        )
            .appendingPathComponent("imessage-mcp-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
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
            approvals: approvals,
            outboundAttachmentStaging: directory.appendingPathComponent(
                "outbound-attachments",
                isDirectory: true
            )
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

@discardableResult
func makeWatcherAvailable(_ events: EventStore) -> UUID {
    let generation = UUID()
    _ = events.beginWatcherGeneration(generation)
    _ = events.publishWatcherAvailable(generation: generation)
    return generation
}
