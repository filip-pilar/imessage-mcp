import Foundation
import Testing
@testable import MessageMCPKit

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
}
