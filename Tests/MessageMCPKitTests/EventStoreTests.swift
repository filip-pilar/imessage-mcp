import Foundation
import Testing
@testable import MessageMCPKit

private final class LockedWaitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LiveEventWaitResult?

    var value: LiveEventWaitResult? { lock.withLock { storage } }
    func set(_ value: LiveEventWaitResult?) { lock.withLock { storage = value } }
}

@Suite("Live event store")
struct EventStoreTests {
    @Test("cursor encodes session and position")
    func cursorRoundTrip() {
        let sessionID = UUID()
        let cursor = LiveEventCursor(sessionID: sessionID, position: 42)

        #expect(LiveEventCursor(rawValue: cursor.rawValue) == cursor)
        #expect(LiveEventCursor(rawValue: "not-a-cursor") == nil)
        #expect(LiveEventCursor(rawValue: "\(sessionID.uuidString):-1") == nil)
    }

    @Test("cursor from another app session expires explicitly")
    func cursorExpiration() throws {
        let oldStore = EventStore(sessionID: UUID())
        _ = oldStore.append(payload: #"{"guid":"OLD"}"#)
        let oldCursor = oldStore.latestCursor.rawValue
        let newStore = EventStore(sessionID: UUID())

        let batch = try newStore.batch(after: oldCursor, limit: 10)

        #expect(batch.cursorExpired)
        #expect(batch.events.isEmpty)
        #expect(batch.cursor.sessionID == newStore.sessionID)
        #expect(batch.cursor.position == 0)
    }

    @Test("cursor expires after retained events roll past it")
    func retentionExpiration() throws {
        let store = EventStore(limit: 2)
        let staleCursor = store.latestCursor.rawValue
        _ = store.append(payload: #"{"guid":"ONE"}"#)
        _ = store.append(payload: #"{"guid":"TWO"}"#)
        _ = store.append(payload: #"{"guid":"THREE"}"#)

        let staleBatch = try store.batch(after: staleCursor, limit: 10)
        let initialBatch = try store.batch(after: nil, limit: 10)

        #expect(staleBatch.cursorExpired)
        #expect(staleBatch.events.isEmpty)
        #expect(!initialBatch.cursorExpired)
        #expect(initialBatch.events.map(\.id) == [2, 3])
    }

    @Test("cursor ahead of the current session expires")
    func futureCursorExpiration() throws {
        let store = EventStore()
        let future = LiveEventCursor(sessionID: store.sessionID, position: 10)

        let batch = try store.batch(after: future.rawValue, limit: 10)

        #expect(batch.cursorExpired)
        #expect(batch.cursor == store.latestCursor)
    }

    @Test("bounded wait times out without polling")
    func boundedTimeout() throws {
        let store = EventStore()
        let started = Date()

        let result = try store.waitForEvents(
            after: store.latestCursor.rawValue,
            timeout: 0.05
        )

        guard case .timedOut(let cursor) = result else {
            Issue.record("Expected a timeout.")
            return
        }
        #expect(cursor == store.latestCursor)
        #expect(Date().timeIntervalSince(started) >= 0.04)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test("invalidation rotates the generation, clears events, and notifies subscribers")
    func invalidationBoundary() throws {
        let store = EventStore()
        let staleCursor = store.latestCursor
        _ = store.append(payload: #"{"guid":"BEFORE-GAP"}"#)
        let notified = DispatchSemaphore(value: 0)
        store.onInvalidated = { cursor in
            #expect(cursor.position == 0)
            notified.signal()
        }

        let freshCursor = store.invalidate()
        let staleBatch = try store.batch(after: staleCursor.rawValue, limit: 10)
        let freshBatch = try store.batch(after: nil, limit: 10)

        #expect(notified.wait(timeout: .now()) == .success)
        #expect(freshCursor.sessionID != staleCursor.sessionID)
        #expect(staleBatch.cursorExpired)
        #expect(staleBatch.events.isEmpty)
        #expect(!freshBatch.cursorExpired)
        #expect(freshBatch.events.isEmpty)
    }

    @Test("invalidation wakes an active wait with cursor expired")
    func invalidationWakesWaiter() throws {
        let store = EventStore()
        let staleCursor = store.latestCursor
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = LockedWaitResult()

        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            result.set(try? store.waitForEvents(after: staleCursor.rawValue, timeout: 5))
            finished.signal()
        }

        #expect(started.wait(timeout: .now() + 1) == .success)
        Thread.sleep(forTimeInterval: 0.02)
        let freshCursor = store.invalidate()

        #expect(finished.wait(timeout: .now() + 1) == .success)
        guard let waitResult = result.value,
              case .cursorExpired(let returnedCursor) = waitResult else {
            Issue.record("Expected invalidation to expire the active wait.")
            return
        }
        #expect(returnedCursor == freshCursor)
    }

    @Test("an old watcher generation cannot append after invalidation")
    func staleGenerationAppend() throws {
        let store = EventStore()
        let staleSessionID = store.sessionID
        _ = store.invalidate()

        let appended = store.append(
            payload: #"{"guid":"LATE-BUFFERED-EVENT"}"#,
            ifSessionID: staleSessionID
        )
        let batch = try store.batch(after: nil, limit: 10)

        #expect(appended == nil)
        #expect(batch.events.isEmpty)
    }
}
