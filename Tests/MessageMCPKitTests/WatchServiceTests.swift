import Darwin
import Foundation
import Testing
@testable import MessageMCPKit

private let fakeIMsgURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-imsg")

private final class LockedCursors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LiveEventCursor] = []

    var values: [LiveEventCursor] { lock.withLock { storage } }
    func append(_ cursor: LiveEventCursor) { lock.withLock { storage.append(cursor) } }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

@Suite("Live event watcher")
struct WatchServiceTests {
    @Test("delivers a short event while the child process remains running")
    func persistentOutput() throws {
        let environment = try TestEnvironment()
        #expect(FileManager.default.isExecutableFile(atPath: fakeIMsgURL.path))

        let received = DispatchSemaphore(value: 0)
        environment.events.onEvent = { _ in received.signal() }
        let watcher = WatchService(
            executableURL: fakeIMsgURL,
            eventStore: environment.events,
            activity: environment.activity,
            processEnvironment: [
                "IMESSAGE_MCP_FAKE_WATCH_EVENT": #"{"chat_id":42,"guid":"LIVE"}"#,
            ]
        )
        defer { watcher.stop() }

        watcher.start()

        #expect(received.wait(timeout: .now() + 3) == .success)
        #expect(environment.events.latestCursor.position == 1)
        #expect(
            try environment.events.batch(after: nil, limit: 1)
                .events.first?.payload.contains("\"LIVE\"") == true
        )
        #expect(watcher.isRunning)
    }

    @Test("an unexpected watcher exit invalidates buffered events before restart")
    func unexpectedExitInvalidatesGeneration() throws {
        let environment = try TestEnvironment()
        let invalidated = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let cursors = LockedCursors()
        environment.events.onInvalidated = { cursor in
            cursors.append(cursor)
            invalidated.signal()
        }
        environment.events.onEvent = { _ in received.signal() }
        let originalCursor = environment.events.latestCursor
        let watcher = WatchService(
            executableURL: fakeIMsgURL,
            eventStore: environment.events,
            activity: environment.activity,
            processEnvironment: [
                "IMESSAGE_MCP_FAKE_WATCH_EVENT": #"{"chat_id":42,"guid":"BEFORE-EXIT"}"#,
                "IMESSAGE_MCP_FAKE_WATCH_EXIT_STATUS": "0",
            ]
        )
        defer { watcher.stop() }

        watcher.start()

        #expect(invalidated.wait(timeout: .now() + 1) == .success)
        #expect(received.wait(timeout: .now() + 3) == .success)
        #expect(invalidated.wait(timeout: .now() + 3) == .success)
        let boundaries = cursors.values
        #expect(boundaries.count >= 2)
        guard boundaries.count >= 2 else { return }
        #expect(boundaries[0].sessionID != originalCursor.sessionID)
        #expect(boundaries[1].sessionID != boundaries[0].sessionID)
        #expect(boundaries[1].position == 0)

        let staleBatch = try environment.events.batch(
            after: boundaries[0].rawValue,
            limit: 10
        )
        let currentBatch = try environment.events.batch(after: nil, limit: 10)
        #expect(staleBatch.cursorExpired)
        #expect(currentBatch.events.isEmpty)
    }

    @Test("disable and re-enable each establish a fresh watcher generation")
    func enablementBoundaries() throws {
        let environment = try TestEnvironment()
        let running = DispatchSemaphore(value: 0)
        let cursors = LockedCursors()
        environment.events.onInvalidated = { cursors.append($0) }
        let originalCursor = environment.events.latestCursor
        let watcher = WatchService(
            executableURL: fakeIMsgURL,
            eventStore: environment.events,
            activity: environment.activity
        )
        watcher.onStateChanged = { isRunning, _ in
            if isRunning { running.signal() }
        }
        defer { watcher.stop() }

        watcher.start()
        #expect(running.wait(timeout: .now() + 3) == .success)
        watcher.stop()

        let stoppedDeadline = Date().addingTimeInterval(1)
        while watcher.isRunning && Date() < stoppedDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        watcher.start()
        watcher.waitForStatePublications()

        let boundaries = cursors.values
        #expect(boundaries.count >= 3)
        guard boundaries.count >= 3 else { return }
        #expect(boundaries[0].sessionID != originalCursor.sessionID)
        #expect(boundaries[1].sessionID != boundaries[0].sessionID)
        #expect(boundaries[2].sessionID != boundaries[1].sessionID)
        #expect(boundaries.allSatisfy { $0.position == 0 })
    }

    @Test("stop publishes watcher unavailability and cursor rotation atomically")
    func stopPublicationOrdering() throws {
        let environment = try TestEnvironment()
        let running = DispatchSemaphore(value: 0)
        let invalidated = DispatchSemaphore(value: 0)
        let cursors = LockedCursors()
        let watcher = WatchService(
            executableURL: fakeIMsgURL,
            eventStore: environment.events,
            activity: environment.activity
        )
        watcher.onStateChanged = { isRunning, _ in
            if isRunning { running.signal() }
        }
        watcher.start()
        #expect(running.wait(timeout: .now() + 3) == .success)
        let runningState = environment.events.watcherState
        #expect(runningState.isAvailable)

        environment.events.onInvalidated = { cursor in
            let state = environment.events.watcherState
            #expect(!state.isAvailable)
            #expect(state.latestCursor == cursor)
            cursors.append(cursor)
            invalidated.signal()
        }
        watcher.stop()

        #expect(invalidated.wait(timeout: .now() + 1) == .success)
        watcher.waitForStatePublications()
        let stoppedState = environment.events.watcherState
        #expect(!stoppedState.isAvailable)
        #expect(stoppedState.latestCursor == cursors.values.last)
        #expect(stoppedState.latestCursor.sessionID != runningState.latestCursor.sessionID)
    }

    @Test("watcher invalidation callbacks can re-enter watcher state")
    func invalidationCallbackReentrancy() throws {
        let environment = try TestEnvironment()
        let callbackFinished = DispatchSemaphore(value: 0)
        let reentryFinished = DispatchSemaphore(value: 0)
        let firstInvalidation = LockedFlag()
        let completed = LockedStrings()
        let watcher = WatchService(
            executableURL: fakeIMsgURL,
            eventStore: environment.events,
            activity: environment.activity
        )
        defer {
            environment.events.onInvalidated = nil
            watcher.stop()
            watcher.waitForStatePublications()
        }
        environment.events.onInvalidated = { _ in
            guard firstInvalidation.claim() else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = watcher.isRunning
                watcher.stop()
                reentryFinished.signal()
            }
            if reentryFinished.wait(timeout: .now() + 1) == .success {
                completed.append("reentered")
            }
            callbackFinished.signal()
        }

        watcher.start()

        #expect(callbackFinished.wait(timeout: .now() + 2) == .success)
        #expect(completed.values == ["reentered"])
    }

    @Test("immediate stop and restart publishes the new unavailable generation")
    func immediateRestartPublishesUnavailable() throws {
        let environment = try TestEnvironment()
        let firstRunningEntered = DispatchSemaphore(value: 0)
        let releaseFirstRunning = DispatchSemaphore(value: 0)
        let restartCallsFinished = DispatchSemaphore(value: 0)
        let newProcessReachedPublication = DispatchSemaphore(value: 0)
        let releaseNewProcess = DispatchSemaphore(value: 0)
        let restartedUnavailable = DispatchSemaphore(value: 0)
        let restartedRunning = DispatchSemaphore(value: 0)
        let firstRunning = LockedFlag()
        let phase = LockedStrings()
        let watcher = WatchService(
            executableURL: fakeIMsgURL,
            eventStore: environment.events,
            activity: environment.activity
        )
        defer {
            releaseFirstRunning.signal()
            releaseNewProcess.signal()
            watcher.stop()
            watcher.waitForStatePublications()
        }
        watcher.onStateChanged = { isRunning, _ in
            if isRunning, firstRunning.claim() {
                firstRunningEntered.signal()
                _ = releaseFirstRunning.wait(timeout: .now() + 2)
                return
            }
            guard phase.values.contains("restarting") else { return }
            if isRunning {
                restartedRunning.signal()
            } else {
                restartedUnavailable.signal()
            }
        }

        watcher.start()
        #expect(firstRunningEntered.wait(timeout: .now() + 3) == .success)
        phase.append("restarting")
        watcher.beforePublishingRunning = { _ in
            newProcessReachedPublication.signal()
            _ = releaseNewProcess.wait(timeout: .now() + 2)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            watcher.stop()
            watcher.start()
            restartCallsFinished.signal()
        }

        #expect(restartCallsFinished.wait(timeout: .now() + 1) == .success)
        releaseFirstRunning.signal()
        #expect(newProcessReachedPublication.wait(timeout: .now() + 3) == .success)
        #expect(restartedUnavailable.wait(timeout: .now() + 2) == .success)
        #expect(!environment.events.watcherState.isAvailable)

        releaseNewProcess.signal()
        #expect(restartedRunning.wait(timeout: .now() + 3) == .success)
        #expect(environment.events.watcherState.isAvailable)
    }

    @Test("a stopped generation cannot publish running after a fresh start")
    func staleRunningPublicationIsRejected() throws {
        let environment = try TestEnvironment()
        let reachedPublication = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let restarted = DispatchSemaphore(value: 0)
        let states = LockedStrings()
        let watcher = WatchService(
            executableURL: fakeIMsgURL,
            eventStore: environment.events,
            activity: environment.activity
        )
        watcher.beforePublishingRunning = { _ in
            reachedPublication.signal()
            _ = releasePublication.wait(timeout: .now() + 2)
        }
        watcher.onStateChanged = { isRunning, _ in
            states.append(isRunning ? "running" : "stopped")
            if isRunning { restarted.signal() }
        }

        watcher.start()
        #expect(reachedPublication.wait(timeout: .now() + 3) == .success)
        let firstGenerationCursor = environment.events.watcherState.latestCursor
        watcher.stop()
        let stoppedCursor = environment.events.watcherState.latestCursor
        #expect(stoppedCursor.sessionID != firstGenerationCursor.sessionID)
        releasePublication.signal()

        let stoppedDeadline = Date().addingTimeInterval(2)
        while watcher.isRunning && Date() < stoppedDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        watcher.waitForStatePublications()
        #expect(!states.values.contains("running"))
        #expect(!environment.events.watcherState.isAvailable)

        watcher.beforePublishingRunning = nil
        watcher.start()
        #expect(restarted.wait(timeout: .now() + 3) == .success)
        let freshState = environment.events.watcherState
        #expect(freshState.isAvailable)
        #expect(freshState.latestCursor.sessionID != stoppedCursor.sessionID)
        watcher.stop()
    }
}
