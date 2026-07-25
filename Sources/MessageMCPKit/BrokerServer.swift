import Foundation

public final class BrokerServer: @unchecked Sendable {
    private struct Client {
        let id: UUID
        let connection: SocketLineConnection
        let session: MCPConnectionSession
        let connectedAt: Date
    }

    private let listener: UnixSocketListener
    private let processor: MCPProcessor
    private let token: String
    private let clientsLock = NSLock()
    private var clients: [UUID: Client] = [:]
    private let workQueue = DispatchQueue(label: "com.openai.imessage-mcp.clients", qos: .userInitiated, attributes: .concurrent)

    public var onClientsChanged: (([MCPClientStatus]) -> Void)?

    public init(socketPath: String, token: String, processor: MCPProcessor) {
        self.listener = UnixSocketListener(path: socketPath)
        self.token = token
        self.processor = processor
    }

    public var clientCount: Int {
        clientsLock.withLock { clients.count }
    }

    public var clientStatuses: [MCPClientStatus] {
        clientsLock.withLock {
            clients.values
                .map {
                    MCPClientStatus(
                        id: $0.id,
                        name: $0.session.clientName,
                        connectedAt: $0.connectedAt,
                        initialized: $0.session.initialized
                    )
                }
                .sorted { $0.connectedAt < $1.connectedAt }
        }
    }

    public func start() throws {
        try listener.start { [weak self] connection in
            guard let self else {
                connection.shutdown()
                return
            }
            self.workQueue.async { [weak self] in
                self?.handle(connection)
            }
        }
    }

    public func stop() {
        listener.stop()
        let current = clientsLock.withLock {
            let values = Array(clients.values)
            clients.removeAll()
            return values
        }
        current.forEach { $0.connection.shutdown() }
        onClientsChanged?([])
    }

    public func notifyEvent() {
        let notification = MCPProcessor.resourceUpdatedNotification(uri: MCPProcessor.eventsURI)
        let current = clientsLock.withLock { Array(clients.values) }
        for client in current where client.session.isSubscribed(to: MCPProcessor.eventsURI) {
            try? client.connection.writeLine(notification)
        }
    }

    private func handle(_ connection: SocketLineConnection) {
        let id = UUID()
        let session = MCPConnectionSession()
        var authenticated = false
        do {
            try connection.readLines { [weak self] line in
                guard let self else { return false }
                if !authenticated {
                    guard
                        let hello = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        hello["type"] as? String == "hello",
                        hello["token"] as? String == self.token
                    else {
                        try? connection.writeLine(Self.json(["type": "hello", "ok": false]))
                        return false
                    }
                    authenticated = true
                    let client = Client(
                        id: id,
                        connection: connection,
                        session: session,
                        connectedAt: Date()
                    )
                    self.clientsLock.withLock { self.clients[id] = client }
                    self.publishClients()
                    try? connection.writeLine(Self.json(["type": "hello", "ok": true]))
                    return true
                }
                if let response = self.processor.process(line: line, session: session) {
                    try? connection.writeLine(response)
                }
                self.publishClients()
                return true
            }
        } catch {
            // Disconnects are expected when MCP clients exit.
        }
        _ = clientsLock.withLock { clients.removeValue(forKey: id) }
        publishClients()
    }

    private func publishClients() {
        onClientsChanged?(clientStatuses)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
