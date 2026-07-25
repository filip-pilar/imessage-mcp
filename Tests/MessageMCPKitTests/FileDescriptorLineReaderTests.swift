import Darwin
import Foundation
import Testing
@testable import MessageMCPKit

private final class LockedLine: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?

    var value: Data? { lock.withLock { storage } }
    func set(_ line: Data) { lock.withLock { storage = line } }
}

@Suite("File descriptor line reader")
struct FileDescriptorLineReaderTests {
    @Test("delivers a short line while stdin remains open")
    func persistentStdin() throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(Darwin.pipe(&descriptors) == 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        let received = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let line = LockedLine()

        DispatchQueue.global().async {
            defer { finished.signal() }
            try? FileDescriptorLineReader.readLines(fileDescriptor: readDescriptor) { value in
                line.set(value)
                received.signal()
                return false
            }
        }

        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        var payload = request
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { rawBuffer in
            Darwin.write(writeDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }

        #expect(written == payload.count)
        let deliveredBeforeEOF = received.wait(timeout: .now() + 0.5) == .success
        Darwin.close(writeDescriptor)

        #expect(deliveredBeforeEOF)
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(line.value == request)
        Darwin.close(readDescriptor)
    }
}
