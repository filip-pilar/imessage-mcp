import Foundation

public final class MCPConnectionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: Set<String> = []
    private var initializedStorage = false
    private var clientNameStorage = "MCP client"

    public init() {}

    public var initialized: Bool {
        lock.withLock { initializedStorage }
    }

    public var clientName: String {
        lock.withLock { clientNameStorage }
    }

    public func markInitialized(clientName: String?) {
        lock.withLock {
            initializedStorage = true
            if let clientName, !clientName.isEmpty { clientNameStorage = clientName }
        }
    }

    public func subscribe(_ uri: String) {
        lock.withLock { _ = subscriptions.insert(uri) }
    }

    public func unsubscribe(_ uri: String) {
        _ = lock.withLock { subscriptions.remove(uri) }
    }

    public func isSubscribed(to uri: String) -> Bool {
        lock.withLock { subscriptions.contains(uri) }
    }
}

public final class MCPProcessor: @unchecked Sendable {
    public static let protocolVersion = "2025-11-25"
    public static let serverVersion = "1.0.0"
    public static let eventsURI = "imessage://events/recent"
    public static let statusURI = "imessage://status"

    private let tools: ToolService
    private let statusProvider: @Sendable () -> [String: Any]

    public init(tools: ToolService, statusProvider: @escaping @Sendable () -> [String: Any]) {
        self.tools = tools
        self.statusProvider = statusProvider
    }

    public func process(line: Data, session: MCPConnectionSession) -> Data? {
        do {
            guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return errorResponse(id: NSNull(), code: -32600, message: "Invalid Request")
            }
            let id = request["id"]
            guard let method = request["method"] as? String else {
                return id.map { errorResponse(id: $0, code: -32600, message: "Invalid Request") } ?? nil
            }
            let params = request["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String
                let supported = ["2025-11-25", "2025-06-18", "2025-03-26"]
                let negotiated = requested.flatMap { supported.contains($0) ? $0 : nil } ?? Self.protocolVersion
                let clientInfo = params["clientInfo"] as? [String: Any]
                session.markInitialized(clientName: clientInfo?["name"] as? String)
                return response(id: id ?? NSNull(), result: [
                    "protocolVersion": negotiated,
                    "capabilities": [
                        "tools": ["listChanged": false],
                        "resources": ["subscribe": true, "listChanged": false],
                        "logging": [:],
                    ],
                    "serverInfo": [
                        "name": "imessage-mcp",
                        "title": "iMessage MCP",
                        "version": Self.serverVersion,
                        "description": "Local iMessage and SMS access through the SIP-enabled imsg surface.",
                    ],
                    "instructions": """
                        Read local Messages history and use guarded write tools for messages, attachments, and standard tapbacks. \
                        react_to_latest always targets the most recent incoming message. Advanced IMCore features that require disabling SIP are intentionally unavailable.
                        """,
                ])

            case "notifications/initialized", "notifications/cancelled":
                return nil

            case "ping":
                return response(id: id ?? NSNull(), result: [:])

            case "tools/list":
                return response(id: id ?? NSNull(), result: [
                    "tools": ToolService.tools.map(\.jsonObject)
                ])

            case "tools/call":
                guard let name = params["name"] as? String else {
                    return errorResponse(id: id ?? NSNull(), code: -32602, message: "Tool name is required.")
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result = tools.call(name: name, arguments: arguments)
                return response(id: id ?? NSNull(), result: result.jsonObject)

            case "resources/list":
                return response(id: id ?? NSNull(), result: [
                    "resources": [
                        [
                            "uri": Self.eventsURI,
                            "name": "Recent iMessage events",
                            "title": "Recent Messages and Reactions",
                            "description": "Live message and reaction events retained in the local broker.",
                            "mimeType": "application/json",
                        ],
                        [
                            "uri": Self.statusURI,
                            "name": "iMessage MCP status",
                            "title": "iMessage MCP Status",
                            "description": "Current broker, policy, connection, and imsg status.",
                            "mimeType": "application/json",
                        ],
                    ]
                ])

            case "resources/read":
                guard let uri = params["uri"] as? String else {
                    return errorResponse(id: id ?? NSNull(), code: -32602, message: "Resource URI is required.")
                }
                let value: Any
                switch uri {
                case Self.eventsURI:
                    let batch = try tools.events.batch(after: nil, limit: 100)
                    value = [
                        "events": batch.events.compactMap { event -> Any? in
                            guard let data = event.payload.data(using: .utf8) else { return nil }
                            return try? JSONSerialization.jsonObject(with: data)
                        },
                        "cursor": batch.cursor.rawValue,
                        "latest_cursor": batch.latestCursor.rawValue,
                    ]
                case Self.statusURI:
                    value = statusProvider()
                default:
                    return errorResponse(id: id ?? NSNull(), code: -32002, message: "Resource not found.")
                }
                let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                return response(id: id ?? NSNull(), result: [
                    "contents": [[
                        "uri": uri,
                        "mimeType": "application/json",
                        "text": String(data: data, encoding: .utf8) ?? "{}",
                    ]]
                ])

            case "resources/subscribe":
                guard let uri = params["uri"] as? String, uri == Self.eventsURI else {
                    return errorResponse(id: id ?? NSNull(), code: -32602, message: "Only \(Self.eventsURI) supports subscriptions.")
                }
                session.subscribe(uri)
                return response(id: id ?? NSNull(), result: [:])

            case "resources/unsubscribe":
                guard let uri = params["uri"] as? String else {
                    return errorResponse(id: id ?? NSNull(), code: -32602, message: "Resource URI is required.")
                }
                session.unsubscribe(uri)
                return response(id: id ?? NSNull(), result: [:])

            case "logging/setLevel":
                return response(id: id ?? NSNull(), result: [:])

            default:
                guard let id else { return nil }
                return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            }
        } catch {
            return errorResponse(id: NSNull(), code: -32603, message: error.localizedDescription)
        }
    }

    public static func resourceUpdatedNotification(uri: String) -> Data {
        encode([
            "jsonrpc": "2.0",
            "method": "notifications/resources/updated",
            "params": ["uri": uri],
        ])
    }

    private func response(id: Any, result: Any) -> Data {
        Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func errorResponse(id: Any, code: Int, message: String) -> Data {
        Self.encode([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ])
    }

    private static func encode(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
