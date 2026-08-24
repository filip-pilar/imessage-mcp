import Darwin
import Foundation
import Testing
@testable import MessageMCPKit

private enum ProxyProcessTestError: Error {
    case executableNotFound
    case processTimedOut
}

private final class ProxyDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?

    var value: Data? { lock.withLock { storage } }

    func set(_ value: Data) {
        lock.withLock { storage = value }
    }
}

@Suite("stdio proxy process")
struct ProxyProcessTests {
    @Test("authenticated broker EOF terminates nonzero while stdin remains open")
    func authenticatedBrokerEOFIsFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let brokerClosed = DispatchSemaphore(value: 0)
        try fixture.listener.start { connection in
            try? connection.readLines { _ in
                try? connection.writeLine(Self.helloAccepted)
                connection.finishWriting()
                brokerClosed.signal()
                return false
            }
        }

        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        let standardError = Pipe()
        let process = try fixture.process(standardInput: input, standardError: standardError)
        defer { Self.stopIfRunning(process) }

        try process.run()
        #expect(brokerClosed.wait(timeout: .now() + 3) == .success)
        try Self.waitForExit(process)

        let errorText = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 1)
        #expect(errorText.contains("authenticated iMessage MCP menu app disconnected"))
    }

    @Test("stdin EOF half-closes and drains broker output")
    func stdinEOFDrainsOutput() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let request = ProxyDataBox()
        let brokerFinished = DispatchSemaphore(value: 0)
        try fixture.listener.start { connection in
            var receivedHello = false
            try? connection.readLines { line in
                if !receivedHello {
                    receivedHello = true
                    try? connection.writeLine(Self.helloAccepted)
                } else {
                    request.set(line)
                }
                return true
            }
            try? connection.writeLine(Self.response)
            connection.finishWriting()
            brokerFinished.signal()
        }

        let input = Pipe()
        let standardOutput = Pipe()
        let process = try fixture.process(standardInput: input, standardOutput: standardOutput)
        defer { Self.stopIfRunning(process) }

        try process.run()
        input.fileHandleForWriting.write(Self.request)
        try input.fileHandleForWriting.close()
        try Self.waitForExit(process)

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        #expect(brokerFinished.wait(timeout: .now() + 3) == .success)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(request.value == Data(Self.request.dropLast()))
        #expect(output == Self.response + Data([0x0A]))
    }

    private struct Fixture {
        let directory: URL
        let listener: UnixSocketListener
        let connectionFile: URL

        init() throws {
            directory = URL(
                fileURLWithPath: "/tmp/imessage-mcp-proxy-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let socketPath = directory.appendingPathComponent("broker.sock").path
            listener = UnixSocketListener(path: socketPath)
            connectionFile = directory.appendingPathComponent("connection.json")
            let info = ConnectionInfo(
                socketPath: socketPath,
                token: "secret",
                appPID: getpid(),
                version: MCPProcessor.serverVersion
            )
            try JSONEncoder().encode(info).write(to: connectionFile, options: .atomic)
        }

        func process(
            standardInput: Pipe,
            standardOutput: Pipe? = nil,
            standardError: Pipe? = nil
        ) throws -> Process {
            let process = Process()
            process.executableURL = try Self.proxyExecutable()
            process.environment = ProcessInfo.processInfo.environment.merging([
                "IMESSAGE_MCP_CONNECTION_FILE": connectionFile.path,
            ]) { _, override in override }
            process.standardInput = standardInput
            if let standardOutput { process.standardOutput = standardOutput }
            if let standardError { process.standardError = standardError }
            return process
        }

        func cleanUp() {
            listener.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        private static func proxyExecutable() throws -> URL {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let builtProduct = repository.appendingPathComponent(".build/debug/imessage-mcp")
            if FileManager.default.isExecutableFile(atPath: builtProduct.path) { return builtProduct }

            var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            while directory.path != "/" {
                let candidate = directory.appendingPathComponent("imessage-mcp")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
            throw ProxyProcessTestError.executableNotFound
        }
    }

    private static func waitForExit(_ process: Process) throws {
        let terminated = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            terminated.signal()
        }
        guard terminated.wait(timeout: .now() + 5) == .success else {
            stopIfRunning(process)
            throw ProxyProcessTestError.processTimedOut
        }
    }

    private static func stopIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static let helloAccepted = Data(#"{"type":"hello","ok":true}"#.utf8)
    private static let request = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8) + Data([0x0A])
    private static let response = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
}
