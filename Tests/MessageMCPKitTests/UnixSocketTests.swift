import Darwin
import Foundation
import Testing
@testable import MessageMCPKit

private final class SocketWriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var errorStorage: Error?
    private var durationStorage: TimeInterval = 0

    var error: Error? { lock.withLock { errorStorage } }
    var duration: TimeInterval { lock.withLock { durationStorage } }

    func finish(error: Error?, duration: TimeInterval) {
        lock.withLock {
            errorStorage = error
            durationStorage = duration
        }
    }
}

@Suite("Local broker socket")
struct UnixSocketTests {
    @Test("round trips newline-delimited data")
    func roundTrip() throws {
        let path = "/tmp/imessage-mcp-test-\(UUID().uuidString.prefix(8)).sock"
        let listener = UnixSocketListener(path: path)
        let accepted = DispatchSemaphore(value: 0)
        try listener.start { connection in
            try? connection.readLines { line in
                try? connection.writeLine(line)
                accepted.signal()
                return false
            }
        }
        defer { listener.stop() }
        let client = try UnixSocketClient.connect(path: path)
        try client.writeLine(Data("hello".utf8))
        var received = ""
        try client.readLines { line in
            received = String(data: line, encoding: .utf8) ?? ""
            return false
        }
        #expect(accepted.wait(timeout: .now() + 1) == .success)
        #expect(received == "hello")
    }

    @Test("closed peers fail writes without SIGPIPE")
    func closedPeerDoesNotSignal() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let connection = try SocketLineConnection(fd: descriptors[0], sendTimeout: 0.1)
        Darwin.close(descriptors[1])

        var noSignal: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: noSignal))
        #expect(Darwin.getsockopt(
            connection.fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            &length
        ) == 0)
        #expect(noSignal == 1)

        #expect(throws: (any Error).self) {
            try connection.writeLine(Data("peer is gone".utf8))
        }
    }

    @Test("send timeout measures stalled progress, not total transfer time")
    func healthyLargeDrainCanExceedTimeout() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let writer = try SocketLineConnection(fd: descriptors[0], sendTimeout: 0.05)
        let readerFD = descriptors[1]
        defer { Darwin.close(readerFD) }

        let payload = Data(repeating: 0x41, count: 20 * 1_024 * 1_024)
        let outcome = SocketWriteOutcome()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            do {
                try writer.writeLine(payload)
                outcome.finish(error: nil, duration: Date().timeIntervalSince(started))
            } catch {
                outcome.finish(error: error, duration: Date().timeIntervalSince(started))
            }
            finished.signal()
        }

        var bytes = [UInt8](repeating: 0, count: 256 * 1_024)
        var received = 0
        while received < payload.count + 1 {
            let remaining = payload.count + 1 - received
            let count = Darwin.recv(readerFD, &bytes, min(bytes.count, remaining), MSG_WAITALL)
            #expect(count > 0)
            guard count > 0 else { break }
            received += count
            usleep(500)
        }

        #expect(finished.wait(timeout: .now() + 3) == .success)
        #expect(outcome.error == nil)
        #expect(received == payload.count + 1)
        #expect(outcome.duration > 0.05)
    }
}
