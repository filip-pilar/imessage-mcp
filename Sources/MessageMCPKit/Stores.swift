import Foundation

struct WritePolicySnapshot: Sendable {
    let settings: AppSettings
    let revision: UInt64
}

public final class SettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var cached: AppSettings
    private var writePolicyRevision: UInt64 = 0

    public init(url: URL = AppPaths.settingsFile) {
        self.url = url
        self.cached = Self.load(from: url) ?? AppSettings()
    }

    public var value: AppSettings {
        lock.withLock { cached }
    }

    var writePolicySnapshot: WritePolicySnapshot {
        lock.withLock {
            WritePolicySnapshot(settings: cached, revision: writePolicyRevision)
        }
    }

    func currentWritePolicy(matching snapshot: WritePolicySnapshot) -> AppSettings? {
        lock.withLock {
            guard writePolicyRevision == snapshot.revision else { return nil }
            return cached
        }
    }

    public func update(_ transform: (inout AppSettings) -> Void) throws {
        try lock.withLock {
            var candidate = cached
            transform(&candidate)
            try Self.write(candidate, to: url)
            if Self.writePolicyChanged(from: cached, to: candidate) {
                writePolicyRevision &+= 1
            }
            cached = candidate
        }
    }

    private static func writePolicyChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        old.writesEnabled != new.writesEnabled
            || old.confirmSends != new.confirmSends
            || old.confirmReactions != new.confirmReactions
            || old.maxAttachmentBytes != new.maxAttachmentBytes
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
    private let publicationQueue = DispatchQueue(label: "com.openai.imessage-mcp.activity-publications")
    private var entries: [ActivityEntry]
    private var persistenceGeneration: UInt64 = 0
    private var lastHandledPersistenceGeneration: UInt64 = 0
    private var lastScheduledDebounceGeneration: UInt64 = 0
    private var lastPublishedGeneration: UInt64 = 0
    private var pendingPersistWork: DispatchWorkItem?
    private var onChangeStorage: (([ActivityEntry]) -> Void)?
    var persistenceWillBegin: (@Sendable (UInt64) -> Void)?
    var debounceWillEnqueue: (@Sendable (UInt64) -> Void)?

    public var onChange: (([ActivityEntry]) -> Void)? {
        get { lock.withLock { onChangeStorage } }
        set { lock.withLock { onChangeStorage = newValue } }
    }

    public init(url: URL = AppPaths.activityFile, limit: Int = 200) {
        self.url = url
        self.limit = limit
        let loaded: [ActivityEntry]
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let persistedData = try? Data(contentsOf: url)
        let shouldPurgeUnreadableLegacy: Bool
        if let persistedData,
           let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: persistedData) {
            loaded = decoded
            shouldPurgeUnreadableLegacy = false
        } else {
            loaded = []
            shouldPurgeUnreadableLegacy = fileExists
        }
        self.entries = Array(loaded.prefix(limit)).map(Self.redactedSummary)
        if shouldPurgeUnreadableLegacy || entries != loaded,
           !persist(entries) {
            Self.purgePersistedActivity(at: url)
        }
    }

    public var recent: [ActivityEntry] {
        lock.withLock { entries }
    }

    public func append(kind: ActivityKind, succeeded: Bool = true) {
        append(
            ActivityEntry(
                kind: kind,
                title: "",
                detail: "",
                succeeded: succeeded
            )
        )
    }

    public func append(_ entry: ActivityEntry) {
        let change = insert(Self.redactedSummary(entry))
        persistenceWillBegin?(change.generation)
        persistenceQueue.sync {
            persistIfNewer(change.snapshot, generation: change.generation)
        }
        enqueuePublication(change.snapshot, generation: change.generation)
    }

    public func appendDebounced(
        kind: ActivityKind,
        succeeded: Bool = true,
        delay: TimeInterval = 2
    ) {
        appendDebounced(
            ActivityEntry(
                kind: kind,
                title: "",
                detail: "",
                succeeded: succeeded
            ),
            delay: delay
        )
    }

    public func appendDebounced(_ entry: ActivityEntry, delay: TimeInterval = 2) {
        let change = insert(Self.redactedSummary(entry))
        enqueuePublication(change.snapshot, generation: change.generation)
        debounceWillEnqueue?(change.generation)
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            guard change.generation > self.lastScheduledDebounceGeneration else {
                return
            }
            self.lastScheduledDebounceGeneration = change.generation
            self.pendingPersistWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.persistenceWillBegin?(change.generation)
                self.persistIfNewer(
                    change.snapshot,
                    generation: change.generation
                )
            }
            self.pendingPersistWork = work
            self.persistenceQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func insert(
        _ entry: ActivityEntry
    ) -> (snapshot: [ActivityEntry], generation: UInt64) {
        lock.withLock {
            entries.insert(entry, at: 0)
            if entries.count > limit {
                entries.removeLast(entries.count - limit)
            }
            persistenceGeneration &+= 1
            return (entries, persistenceGeneration)
        }
    }

    private func persistIfNewer(
        _ snapshot: [ActivityEntry],
        generation: UInt64
    ) {
        guard generation > lastHandledPersistenceGeneration else { return }
        lastHandledPersistenceGeneration = generation
        _ = persist(snapshot)
    }

    func waitForPersistence() {
        persistenceQueue.sync {}
    }

    func waitForPublications() {
        publicationQueue.sync {}
    }

    private func enqueuePublication(
        _ snapshot: [ActivityEntry],
        generation: UInt64
    ) {
        publicationQueue.async { [weak self] in
            guard let self else { return }
            let publication = self.lock.withLock {
                (
                    isCurrent: generation == self.persistenceGeneration,
                    callback: self.onChangeStorage
                )
            }
            guard publication.isCurrent else { return }
            guard generation > self.lastPublishedGeneration else { return }
            self.lastPublishedGeneration = generation
            publication.callback?(snapshot)
        }
    }

    @discardableResult
    private func persist(_ snapshot: [ActivityEntry]) -> Bool {
        do {
            try AppPaths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    private static func purgePersistedActivity(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            return
        } catch {
            // Atomic replacement can fail in a locked directory even when the
            // existing file itself is writable. Overwrite it in place so
            // legacy sensitive contents are not left behind.
        }
        try? Data("[]\n".utf8).write(to: url)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func redactedSummary(_ entry: ActivityEntry) -> ActivityEntry {
        let summary: (title: String, detail: String)
        switch entry.kind {
        case .read:
            summary = ("Read operation", "Request details redacted.")
        case .send:
            summary = ("Message sent", "Recipient and content redacted.")
        case .reaction:
            summary = ("Tapback sent", "Conversation and target redacted.")
        case .event:
            summary = ("Messages activity", "Conversation details redacted.")
        case .diagnostic:
            summary = ("Diagnostic", "Diagnostic details redacted.")
        case .error:
            summary = ("Operation failed", "Error details not persisted.")
        }
        return ActivityEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            kind: entry.kind,
            title: summary.title,
            detail: summary.detail,
            succeeded: entry.succeeded
        )
    }
}

public final class EventStore: @unchecked Sendable {
    private let condition = NSCondition()
    private let limit: Int
    private var currentSessionID: UUID
    private var watcherGeneration = UUID()
    private var watcherAvailable = false
    private var nextID: Int64 = 1
    private var events: [LiveEvent] = []
    var waitWillBlock: (@Sendable () -> Void)?
    public var onEvent: ((LiveEvent) -> Void)?
    public var onInvalidated: ((LiveEventCursor) -> Void)?

    public init(limit: Int = 500, sessionID: UUID = UUID()) {
        self.limit = limit
        self.currentSessionID = sessionID
    }

    public var sessionID: UUID {
        condition.withLock { currentSessionID }
    }

    @discardableResult
    public func append(payload: String) -> LiveEvent {
        append(payload: payload, ifSessionID: nil)!
    }

    @discardableResult
    public func append(payload: String, ifSessionID expectedSessionID: UUID) -> LiveEvent? {
        append(payload: payload, ifSessionID: Optional(expectedSessionID))
    }

    @discardableResult
    public func invalidate() -> LiveEventCursor {
        condition.lock()
        watcherAvailable = false
        let cursor = rotateCursorLocked()
        condition.broadcast()
        condition.unlock()
        publishInvalidation(cursor)
        return cursor
    }

    public var watcherState: LiveEventWatcherState {
        condition.withLock {
            LiveEventWatcherState(
                isAvailable: watcherAvailable,
                latestCursor: latestCursorLocked
            )
        }
    }

    @discardableResult
    func beginWatcherGeneration(_ generation: UUID) -> LiveEventWatcherState {
        condition.lock()
        watcherGeneration = generation
        watcherAvailable = false
        let cursor = rotateCursorLocked()
        let state = LiveEventWatcherState(isAvailable: false, latestCursor: cursor)
        condition.broadcast()
        condition.unlock()
        return state
    }

    func publishWatcherAvailable(
        generation: UUID
    ) -> LiveEventWatcherState? {
        condition.withLock {
            guard generation == watcherGeneration else { return nil }
            watcherAvailable = true
            return LiveEventWatcherState(
                isAvailable: true,
                latestCursor: latestCursorLocked
            )
        }
    }

    @discardableResult
    func breakWatcherContinuity(
        generation: UUID
    ) -> LiveEventWatcherState? {
        condition.lock()
        guard generation == watcherGeneration else {
            condition.unlock()
            return nil
        }
        watcherAvailable = false
        let cursor = rotateCursorLocked()
        let state = LiveEventWatcherState(isAvailable: false, latestCursor: cursor)
        condition.broadcast()
        condition.unlock()
        return state
    }

    @discardableResult
    func endWatcherGeneration(
        _ generation: UUID
    ) -> LiveEventWatcherState? {
        condition.lock()
        guard generation == watcherGeneration else {
            condition.unlock()
            return nil
        }
        watcherGeneration = UUID()
        watcherAvailable = false
        let cursor = rotateCursorLocked()
        let state = LiveEventWatcherState(isAvailable: false, latestCursor: cursor)
        condition.broadcast()
        condition.unlock()
        return state
    }

    func publishInvalidation(_ cursor: LiveEventCursor) {
        onInvalidated?(cursor)
    }

    private func append(payload: String, ifSessionID expectedSessionID: UUID?) -> LiveEvent? {
        condition.lock()
        if let expectedSessionID, expectedSessionID != currentSessionID {
            condition.unlock()
            return nil
        }
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
        limit requestedLimit: Int = 200,
        cancellation: ToolCallCancellation? = nil
    ) throws -> LiveEventWaitResult {
        let cancellationObserver = cancellation?.observe { [weak self] in
            guard let self else { return }
            condition.withLock { condition.broadcast() }
        }
        defer { cancellation?.removeObserver(cancellationObserver) }

        condition.lock()
        defer { condition.unlock() }

        guard let requested = LiveEventCursor(rawValue: rawCursor) else {
            throw ToolServiceError.invalid("cursor is malformed.")
        }
        guard requested.sessionID == currentSessionID else {
            return .cursorExpired(latestCursorLocked)
        }
        guard !isUnavailablePositionLocked(requested.position) else {
            return .cursorExpired(latestCursorLocked)
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if cancellation?.isCancelled == true {
                throw ToolServiceError.disabled("The request was cancelled by the MCP client.")
            }
            guard requested.sessionID == currentSessionID else {
                return .cursorExpired(latestCursorLocked)
            }
            let batch = try batchLocked(after: requested.rawValue, limit: requestedLimit)
            if batch.cursorExpired {
                return .cursorExpired(batch.latestCursor)
            }
            if !batch.events.isEmpty { return .events(batch) }
            waitWillBlock?()
            guard condition.wait(until: deadline) else {
                if cancellation?.isCancelled == true {
                    throw ToolServiceError.disabled("The request was cancelled by the MCP client.")
                }
                return .timedOut(latestCursorLocked)
            }
        }
    }

    public var latestCursor: LiveEventCursor {
        condition.withLock { latestCursorLocked }
    }

    private var latestCursorLocked: LiveEventCursor {
        LiveEventCursor(sessionID: currentSessionID, position: events.last?.id ?? 0)
    }

    private func rotateCursorLocked() -> LiveEventCursor {
        currentSessionID = UUID()
        nextID = 1
        events.removeAll()
        return latestCursorLocked
    }

    private func batchLocked(after rawCursor: String?, limit requestedLimit: Int) throws -> LiveEventBatch {
        let requested: LiveEventCursor
        if let rawCursor {
            guard let decoded = LiveEventCursor(rawValue: rawCursor) else {
                throw ToolServiceError.invalid("cursor is malformed.")
            }
            requested = decoded
        } else {
            requested = LiveEventCursor(sessionID: currentSessionID, position: 0)
        }

        let latest = latestCursorLocked
        guard requested.sessionID == currentSessionID else {
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
                sessionID: currentSessionID,
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
