import Foundation

private final class InFlightToolCallLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var count = 0

    init(maximum: Int) {
        self.maximum = max(1, maximum)
    }

    func acquire() -> Bool {
        lock.withLock {
            guard count < maximum else { return false }
            count += 1
            return true
        }
    }

    func release() {
        lock.withLock {
            count = max(0, count - 1)
        }
    }
}

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
    private var acceptingWork = false
    private let inFlightToolCalls: InFlightToolCallLimiter
    private let workerGroup = DispatchGroup()
    private let workQueue = DispatchQueue(label: "com.openai.imessage-mcp.clients", qos: .userInitiated, attributes: .concurrent)

    public var onClientsChanged: (([MCPClientStatus]) -> Void)?

    public init(
        socketPath: String,
        token: String,
        processor: MCPProcessor,
        maximumInFlightToolCalls: Int = 32
    ) {
        self.listener = UnixSocketListener(path: socketPath)
        self.token = token
        self.processor = processor
        self.inFlightToolCalls = InFlightToolCallLimiter(
            maximum: maximumInFlightToolCalls
        )
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
        clientsLock.withLock { acceptingWork = true }
        do {
            try listener.start { [weak self] connection in
                guard let self else {
                    connection.shutdown()
                    return
                }
                self.workQueue.async { [weak self] in
                    self?.handle(connection)
                }
            }
        } catch {
            clientsLock.withLock { acceptingWork = false }
            throw error
        }
    }

    public func stop() {
        _ = stopAndDrain(timeout: 65)
    }

    @discardableResult
    public func stopAndDrain(timeout: TimeInterval) -> Bool {
        listener.stop()
        let current = clientsLock.withLock {
            acceptingWork = false
            let values = Array(clients.values)
            clients.removeAll()
            return values
        }
        current.forEach {
            $0.session.cancelAllRequests()
            $0.connection.shutdown()
        }
        let drained = workerGroup.wait(
            timeout: .now() + max(0, timeout)
        ) == .success
        onClientsChanged?([])
        return drained
    }

    public func notifyEvent() {
        let notification = MCPProcessor.resourceUpdatedNotification(uri: MCPProcessor.eventsURI)
        let current = clientsLock.withLock { Array(clients.values) }
        var failedClientIDs: Set<UUID> = []
        for client in current where client.session.isSubscribed(to: MCPProcessor.eventsURI) {
            do {
                try client.connection.writeLine(notification)
            } catch {
                failedClientIDs.insert(client.id)
            }
        }
        guard !failedClientIDs.isEmpty else { return }
        failedClientIDs.forEach(disconnectClient)
    }

    private func handle(_ connection: SocketLineConnection) {
        let id = UUID()
        let session = MCPConnectionSession()
        let sessionWorkers = DispatchGroup()
        var authenticated = false
        var readFailed = false
        do {
            try connection.readLines { [weak self] line in
                guard let self else { return false }
                if !authenticated {
                    guard
                        let hello = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        hello["type"] as? String == "hello",
                        hello["token"] as? String == self.token
                    else {
                        do {
                            try connection.writeLine(Self.json(["type": "hello", "ok": false]))
                        } catch {
                            connection.shutdown()
                        }
                        return false
                    }
                    authenticated = true
                    let client = Client(
                        id: id,
                        connection: connection,
                        session: session,
                        connectedAt: Date()
                    )
                    let accepted = self.clientsLock.withLock { () -> Bool in
                        guard self.acceptingWork else { return false }
                        self.clients[id] = client
                        return true
                    }
                    guard accepted else {
                        connection.shutdown()
                        return false
                    }
                    self.publishClients()
                    do {
                        try connection.writeLine(Self.json(["type": "hello", "ok": true]))
                    } catch {
                        connection.shutdown()
                        return false
                    }
                    return true
                }
                switch self.processor.prepareAsynchronousToolCall(line: line, session: session) {
                case .accepted:
                    let workerReserved = self.clientsLock.withLock { () -> Bool in
                        guard self.acceptingWork else { return false }
                        self.workerGroup.enter()
                        return true
                    }
                    guard workerReserved else {
                        session.cancelAllRequests()
                        return false
                    }
                    guard self.inFlightToolCalls.acquire() else {
                        self.workerGroup.leave()
                        if let response = self.processor.rejectPreparedToolCallForOverload(
                            line: line,
                            session: session
                        ) {
                            do {
                                try connection.writeLine(response)
                            } catch {
                                self.disconnectClient(id)
                                return false
                            }
                        }
                        return true
                    }
                    sessionWorkers.enter()
                    let limiter = self.inFlightToolCalls
                    let processor = self.processor
                    let workerGroup = self.workerGroup
                    self.workQueue.async { [weak self] in
                        defer {
                            processor.finishAsynchronousToolCall(
                                line: line,
                                session: session
                            )
                            limiter.release()
                            sessionWorkers.leave()
                            workerGroup.leave()
                        }
                        guard let self else {
                            session.cancelAllRequests()
                            return
                        }
                        if let response = self.processor.process(
                            line: line,
                            session: session,
                            finishRequestWhenComplete: false
                        ) {
                            do {
                                try connection.writeLine(response)
                            } catch {
                                self.disconnectClient(id)
                                return
                            }
                        }
                        self.publishClients()
                    }
                    return true
                case .rejected(let response):
                    do {
                        try connection.writeLine(response)
                    } catch {
                        self.disconnectClient(id)
                        return false
                    }
                    return true
                case .notAsynchronousToolCall:
                    break
                }
                if let response = self.processor.process(line: line, session: session) {
                    do {
                        try connection.writeLine(response)
                    } catch {
                        self.disconnectClient(id)
                        return false
                    }
                }
                self.publishClients()
                return true
            }
        } catch {
            readFailed = true
            // Disconnects are expected when MCP clients exit.
        }
        session.cancelAllRequests()
        if !readFailed {
            _ = sessionWorkers.wait(timeout: .now() + 1)
        }
        disconnectClient(id)
    }

    private func disconnectClient(_ id: UUID) {
        let removed = clientsLock.withLock { clients.removeValue(forKey: id) }
        guard let removed else { return }
        removed.session.cancelAllRequests()
        removed.connection.shutdown()
        publishClients()
    }

    private func publishClients() {
        onClientsChanged?(clientStatuses)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
