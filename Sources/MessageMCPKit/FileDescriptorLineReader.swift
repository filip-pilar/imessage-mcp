import Darwin
import Foundation

public enum FileDescriptorLineReader {
    public static func readLines(
        fileDescriptor: Int32 = STDIN_FILENO,
        _ handler: (Data) throws -> Bool
    ) throws {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)

        while true {
            let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.system("read", errno)
            }

            buffer.append(bytes, count: count)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                if try !handler(Data(line)) { return }
            }
        }
    }
}
