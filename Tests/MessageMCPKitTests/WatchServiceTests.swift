import Darwin
import Foundation
import Testing
@testable import MessageMCPKit

@Suite("Live event watcher")
struct WatchServiceTests {
    @Test("delivers a short event while the child process remains running")
    func persistentOutput() throws {
        let environment = try TestEnvironment()
        let executable = environment.directory.appendingPathComponent("persistent-watch")
        let script = """
            #!/bin/sh
            printf '%s\\n' '{"chat_id":42,"guid":"LIVE"}'
            sleep 8
            """
        try Data(script.utf8).write(to: executable)
        #expect(Darwin.chmod(executable.path, 0o700) == 0)

        let received = DispatchSemaphore(value: 0)
        environment.events.onEvent = { _ in received.signal() }
        let watcher = WatchService(
            executableURL: executable,
            eventStore: environment.events,
            activity: environment.activity
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

    @Test("extracts friendly chat labels without routing identifiers")
    func chatLabels() {
        let labels = WatchService.chatLabels(from: [
            ["id": 42, "contact_name": "Fixture Person"],
            ["id": 43, "name": "+441234567890"],
            ["id": "44", "display_name": "Project Group"],
            ["id": 45, "contact_name": "person@example.com"],
        ])

        #expect(labels[42] == "Fixture Person")
        #expect(labels[43] == nil)
        #expect(labels[44] == "Project Group")
        #expect(labels[45] == nil)
    }

    @Test("presents message activity with friendly name and secondary chat ID")
    func activityPresentation() {
        let incoming = WatchService.activityEntry(
            for: Data(#"{"chat_id":42,"is_from_me":false}"#.utf8),
            chatLabels: [42: "Fixture Person"]
        )
        let reaction = WatchService.activityEntry(
            for: Data(#"{"chat_id":"44","is_reaction":true}"#.utf8),
            chatLabels: [44: "Project Group"]
        )

        #expect(incoming.title == "New message")
        #expect(incoming.detail == "Fixture Person · Chat 42")
        #expect(reaction.title == "New reaction")
        #expect(reaction.detail == "Project Group · Chat 44")
    }
}
