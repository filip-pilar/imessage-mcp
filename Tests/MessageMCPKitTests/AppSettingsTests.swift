import Foundation
import Testing
@testable import MessageMCPKit

private final class LockedActivitySnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[ActivityEntry]] = []

    var values: [[ActivityEntry]] { lock.withLock { storage } }
    func append(_ snapshot: [ActivityEntry]) { lock.withLock { storage.append(snapshot) } }
}

@Suite("App settings")
struct AppSettingsTests {
    @Test("older settings preserve supported values and legacy launch state")
    func backwardCompatibleDecoding() throws {
        let data = Data("""
        {
          "writesEnabled": false,
          "confirmSends": false,
          "confirmReactions": true,
          "liveEventsEnabled": false,
          "launchAtLogin": true,
          "maxAttachmentBytes": 1024,
          "imsgOverridePath": "/tmp/fake-imsg"
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(settings.writesEnabled == false)
        #expect(settings.confirmSends == false)
        #expect(settings.confirmReactions == true)
        #expect(settings.approvalNotificationsEnabled == false)
        #expect(settings.liveEventsEnabled == false)
        #expect(settings.launchAtLogin == true)
        #expect(settings.maxAttachmentBytes == 1024)
        #expect(settings.imsgOverridePath == "/tmp/fake-imsg")
    }

    @Test("failed persistence leaves the in-memory policy unchanged")
    func transactionalPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-mcp-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let store = SettingsStore(url: blockingFile.appendingPathComponent("settings.json"))
        let policySnapshot = store.writePolicySnapshot

        #expect(store.value.writesEnabled)
        #expect(throws: (any Error).self) {
            try store.update { $0.writesEnabled = false }
        }
        #expect(store.value.writesEnabled)
        #expect(store.currentWritePolicy(matching: policySnapshot) != nil)
    }

    @Test("activity persistence redacts new and legacy sensitive details")
    func activityRedaction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-mcp-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.json")
        let legacy = [
            ActivityEntry(
                kind: .read,
                title: "Looked up handle",
                detail: "private@example.invalid"
            ),
            ActivityEntry(
                kind: .error,
                title: "send_message",
                detail: "adapter echoed SECRET_BODY to private@example.invalid",
                succeeded: false
            ),
        ]
        try JSONEncoder().encode(legacy).write(to: url)

        let store = ActivityStore(url: url)
        store.append(ActivityEntry(
            kind: .send,
            title: "Message sent",
            detail: "+15555550123 SECRET_BODY"
        ))

        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(!persisted.contains("private@example.invalid"))
        #expect(!persisted.contains("+15555550123"))
        #expect(!persisted.contains("SECRET_BODY"))
        #expect(store.recent.allSatisfy { !$0.detail.contains("private@example.invalid") })
        #expect(store.recent.first?.title == "Message sent")
        #expect(store.recent.first?.detail == "Recipient and content redacted.")
    }

    @Test("unreadable legacy activity is purged")
    func corruptActivityPurge() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-mcp-corrupt-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.json")
        try Data("private@example.invalid SECRET_BODY".utf8).write(to: url)

        let store = ActivityStore(url: url)

        #expect(store.recent.isEmpty)
        let persisted = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!persisted.contains("private@example.invalid"))
        #expect(!persisted.contains("SECRET_BODY"))
    }

    @Test("an older activity snapshot cannot overwrite a newer persisted history")
    func activityPersistenceOrdering() throws {
        let environment = try TestEnvironment()
        let url = environment.directory.appendingPathComponent("ordered-activity.json")
        let store = ActivityStore(url: url)
        let firstReachedPersistence = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        store.persistenceWillBegin = { generation in
            if generation == 1 {
                firstReachedPersistence.signal()
                _ = releaseFirst.wait(timeout: .now() + 1)
            }
        }

        DispatchQueue.global().async {
            store.append(kind: .read)
            firstFinished.signal()
        }
        #expect(firstReachedPersistence.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async {
            store.append(kind: .send)
            secondFinished.signal()
        }
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
        releaseFirst.signal()
        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        store.waitForPersistence()

        let persisted = try JSONDecoder().decode(
            [ActivityEntry].self,
            from: Data(contentsOf: url)
        )
        #expect(persisted.map(\.id) == store.recent.map(\.id))
        #expect(persisted.map(\.kind) == [.send, .read])
    }

    @Test("stale activity generations cannot regress observer state")
    func activityObserverOrdering() throws {
        let environment = try TestEnvironment()
        let store = ActivityStore(
            url: environment.directory.appendingPathComponent("observer-activity.json")
        )
        let firstBlocked = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let published = DispatchSemaphore(value: 0)
        let snapshots = LockedActivitySnapshots()
        store.persistenceWillBegin = { generation in
            if generation == 1 {
                firstBlocked.signal()
                _ = releaseFirst.wait(timeout: .now() + 1)
            }
        }
        store.onChange = { snapshot in
            snapshots.append(snapshot)
            published.signal()
        }

        DispatchQueue.global().async {
            store.append(kind: .read)
            firstFinished.signal()
        }
        #expect(firstBlocked.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async {
            store.append(kind: .send)
            secondFinished.signal()
        }
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
        #expect(published.wait(timeout: .now() + 1) == .success)
        releaseFirst.signal()
        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        store.waitForPublications()

        #expect(snapshots.values.count == 1)
        #expect(snapshots.values.first?.map(\.kind) == [.send, .read])
    }

    @Test("older reversed debounce work cannot cancel a newer generation")
    func activityDebounceEnqueueOrdering() throws {
        let environment = try TestEnvironment()
        let url = environment.directory.appendingPathComponent("debounced-activity.json")
        let store = ActivityStore(url: url)
        let firstBlocked = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let secondPersisted = DispatchSemaphore(value: 0)
        store.debounceWillEnqueue = { generation in
            if generation == 1 {
                firstBlocked.signal()
                _ = releaseFirst.wait(timeout: .now() + 1)
            }
        }
        store.persistenceWillBegin = { generation in
            if generation == 2 { secondPersisted.signal() }
        }

        DispatchQueue.global().async {
            store.appendDebounced(kind: .read, delay: 0.02)
            firstFinished.signal()
        }
        #expect(firstBlocked.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async {
            store.appendDebounced(kind: .send, delay: 0.02)
            secondFinished.signal()
        }
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
        releaseFirst.signal()
        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        #expect(secondPersisted.wait(timeout: .now() + 1) == .success)
        store.waitForPersistence()

        let persisted = try JSONDecoder().decode(
            [ActivityEntry].self,
            from: Data(contentsOf: url)
        )
        #expect(persisted.map(\.kind) == [.send, .read])
    }
}
