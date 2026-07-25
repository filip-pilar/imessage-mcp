import Foundation
import Testing
@testable import MessageMCPKit

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
}
