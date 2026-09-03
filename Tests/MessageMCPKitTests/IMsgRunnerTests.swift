import Foundation
import Testing
@testable import MessageMCPKit

@Suite("imsg process adapter")
struct IMsgRunnerTests {
    @Test("passes arguments without shell interpolation")
    func argumentsAreNotShellEvaluated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imsg-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-imsg")
        let marker = directory.appendingPathComponent("should-not-exist")
        let source = """
        #!/bin/sh
        printf '{"argument":"%s"}\\n' "$1"
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let malicious = "$(touch \(marker.path))"
        let output = try IMsgRunner(executableURL: script).run(arguments: [malicious], timeout: 5)

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(output.stdout.contains(malicious))
    }

    @Test("returns stderr for failed commands")
    func reportsFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imsg-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-imsg")
        try Data("#!/bin/sh\necho 'permission denied' >&2\nexit 7\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        #expect(throws: IMsgRunnerError.self) {
            _ = try IMsgRunner(executableURL: script).run(arguments: ["chats"], timeout: 5)
        }
    }

    @Test("speaks one-shot imsg JSON-RPC")
    func rpc() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imsg-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-imsg")
        let source = """
        #!/bin/sh
        read request
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"send_state":"delivered"}}'
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let result = try IMsgRunner(executableURL: script).rpc(
            method: "message.send_status",
            params: ["guid": "ABC"],
            timeout: 5
        ) as? [String: Any]
        #expect(result?["send_state"] as? String == "delivered")
    }

    @Test("blocked RPC stdin times out without hanging")
    func blockedRPCStdinTimesOut() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-imsg")
        var environment = ProcessInfo.processInfo.environment
        environment["IMESSAGE_MCP_FAKE_BLOCK_RPC_STDIN"] = "1"
        let runner = IMsgRunner(executableURL: fixture, environment: environment)
        let started = ContinuousClock.now

        #expect(throws: IMsgRunnerError.timedOut) {
            _ = try runner.rpc(
                method: "test.blocked",
                params: ["payload": String(repeating: "x", count: 1024 * 1024)],
                timeout: 0.5
            )
        }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("TERM-resistant direct child is gone before return")
    func termResistantChildIsGone() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-imsg")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imsg-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let runner = IMsgRunner(executableURL: fixture)
        let started = ContinuousClock.now

        #expect(throws: IMsgRunnerError.timedOut) {
            _ = try runner.run(arguments: ["test-term-resistant", pidFile.path], timeout: 0.6)
        }
        #expect(started.duration(to: .now) < .seconds(2))

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
