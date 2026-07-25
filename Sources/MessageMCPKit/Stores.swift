import Foundation

public final class SettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var cached: AppSettings

    public init(url: URL = AppPaths.settingsFile) {
        self.url = url
        self.cached = Self.load(from: url) ?? AppSettings()
    }

    public var value: AppSettings {
        lock.withLock { cached }
    }

    public func update(_ transform: (inout AppSettings) -> Void) throws {
        try lock.withLock {
            transform(&cached)
            try Self.write(cached, to: url)
        }
    }

    private static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    private static func write(_ settings: AppSettings, to url: URL) throws {
        try AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

public final class ActivityStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let limit: Int
    private let persistenceQueue = DispatchQueue(label: "com.openai.imessage-mcp.activity-persistence")
    private var entries: [ActivityEntry]
    private var pendingPersistWork: DispatchWorkItem?
    public var onChange: (([ActivityEntry]) -> Void)?

    public init(url: URL = AppPaths.activityFile, limit: Int = 200) {
        self.url = url
        self.limit = limit
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = []
        }
    }

    public var recent: [ActivityEntry] {
        lock.withLock { entries }
    }

    public func append(_ entry: ActivityEntry) {
        let snapshot = insert(entry)
        persist(snapshot)
        onChange?(snapshot)
    }

    public func appendDebounced(_ entry: ActivityEntry, delay: TimeInterval = 2) {
        let snapshot = insert(entry)
        onChange?(snapshot)
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            self.pendingPersistWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.persist(self.recent)
            }
            self.pendingPersistWork = work
            self.persistenceQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func insert(_ entry: ActivityEntry) -> [ActivityEntry] {
        lock.withLock {
            entries.insert(entry, at: 0)
            if entries.count > limit {
                entries.removeLast(entries.count - limit)
            }
            return entries
        }
    }

    private func persist(_ snapshot: [ActivityEntry]) {
        try? AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }
}

public final class EventStore: @unchecked Sendable {
    private let condition = NSCondition()
    private let limit: Int
    public let sessionID: UUID
    private var nextID: Int64 = 1
    private var events: [LiveEvent] = []
    public var onEvent: ((LiveEvent) -> Void)?

    public init(limit: Int = 500, sessionID: UUID = UUID()) {
        self.limit = limit
        self.sessionID = sessionID
    }

    @discardableResult
    public func append(payload: String) -> LiveEvent {
        condition.lock()
        let event = LiveEvent(id: nextID, payload: payload)
        nextID += 1
        events.append(event)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
        condition.broadcast()
        condition.unlock()
        onEvent?(event)
        return event
    }

    public func batch(after rawCursor: String?, limit requestedLimit: Int) throws -> LiveEventBatch {
        try condition.withLock {
            try batchLocked(after: rawCursor, limit: requestedLimit)
        }
    }

    public func waitForEvents(
        after rawCursor: String,
        timeout: TimeInterval,
        limit requestedLimit: Int = 200
    ) throws -> LiveEventWaitResult {
        condition.lock()
        defer { condition.unlock() }

        guard let requested = LiveEventCursor(rawValue: rawCursor) else {
            throw ToolServiceError.invalid("cursor is malformed.")
        }
        guard requested.sessionID == sessionID else {
            return .cursorExpired(latestCursorLocked)
        }
        guard !isUnavailablePositionLocked(requested.position) else {
            return .cursorExpired(latestCursorLocked)
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            let batch = try batchLocked(after: requested.rawValue, limit: requestedLimit)
            if !batch.events.isEmpty { return .events(batch) }
            guard condition.wait(until: deadline) else {
                return .timedOut(latestCursorLocked)
            }
        }
    }

    public var latestCursor: LiveEventCursor {
        condition.withLock { latestCursorLocked }
    }

    private var latestCursorLocked: LiveEventCursor {
        LiveEventCursor(sessionID: sessionID, position: events.last?.id ?? 0)
    }

    private func batchLocked(after rawCursor: String?, limit requestedLimit: Int) throws -> LiveEventBatch {
        let requested: LiveEventCursor
        if let rawCursor {
            guard let decoded = LiveEventCursor(rawValue: rawCursor) else {
                throw ToolServiceError.invalid("cursor is malformed.")
            }
            requested = decoded
        } else {
            requested = LiveEventCursor(sessionID: sessionID, position: 0)
        }

        let latest = latestCursorLocked
        guard requested.sessionID == sessionID else {
            return LiveEventBatch(
                events: [],
                cursor: latest,
                latestCursor: latest,
                cursorExpired: true
            )
        }
        if rawCursor != nil, isUnavailablePositionLocked(requested.position) {
            return LiveEventBatch(
                events: [],
                cursor: latest,
                latestCursor: latest,
                cursorExpired: true
            )
        }

        let values = Array(
            events.lazy
                .filter { $0.id > requested.position }
                .prefix(max(1, min(requestedLimit, 200)))
        )
        return LiveEventBatch(
            events: values,
            cursor: LiveEventCursor(
                sessionID: sessionID,
                position: values.last?.id ?? requested.position
            ),
            latestCursor: latest,
            cursorExpired: false
        )
    }

    private func isUnavailablePositionLocked(_ position: Int64) -> Bool {
        let latestPosition = events.last?.id ?? 0
        if position > latestPosition { return true }
        guard let firstPosition = events.first?.id else { return false }
        return position < firstPosition - 1
    }
}
