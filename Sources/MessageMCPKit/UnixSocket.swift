import Foundation
import Darwin

public enum UnixSocketError: LocalizedError {
    case system(String, Int32)
    case pathTooLong
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .system(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .pathTooLong:
            return "The local socket path is too long."
        case .disconnected:
            return "The iMessage MCP menu app disconnected."
        }
    }
}

private func socketAddress(path: String) throws -> (sockaddr_un, socklen_t) {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else { throw UnixSocketError.pathTooLong }
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
        bytes.withUnsafeBytes { raw in
            memcpy(pointer, raw.baseAddress!, bytes.count)
        }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    return (address, length)
}

public final class SocketLineConnection: @unchecked Sendable {
    public static let defaultSendTimeout: TimeInterval = 1

    public let fd: Int32
    private let writeLock = NSLock()

    @available(*, deprecated, message: "Use init(fd:sendTimeout:) to surface socket setup failures.")
    public init(fd: Int32) {
        self.fd = fd
        try? Self.configure(fd: fd, sendTimeout: Self.defaultSendTimeout)
    }

    public init(fd: Int32, sendTimeout: TimeInterval?) throws {
        self.fd = fd
        do {
            try Self.configure(fd: fd, sendTimeout: sendTimeout)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit {
        Darwin.close(fd)
    }

    public func readLines(_ handler: (Data) -> Bool) throws {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
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
                if !handler(Data(line)) { return }
            }
        }
    }

    public func writeLine(_ data: Data) throws {
        try writeLock.withLock {
            var payload = data
            payload.append(0x0A)
            try payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw UnixSocketError.system("write", errno)
                    }
                    if count == 0 { throw UnixSocketError.disconnected }
                    offset += count
                }
            }
        }
    }

    public func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    public func finishWriting() {
        Darwin.shutdown(fd, SHUT_WR)
    }

    private static func configure(fd: Int32, sendTimeout: TimeInterval?) throws {
        var noSignal: Int32 = 1
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw UnixSocketError.system("setsockopt(SO_NOSIGPIPE)", errno)
        }

        guard let sendTimeout else { return }
        let seconds = max(0, sendTimeout)
        var timeout = timeval()
        timeout.tv_sec = Int(seconds)
        timeout.tv_usec = Int32((seconds - floor(seconds)) * 1_000_000)
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        ) == 0 else {
            throw UnixSocketError.system("setsockopt(SO_SNDTIMEO)", errno)
        }
    }
}

public final class UnixSocketListener: @unchecked Sendable {
    public let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.openai.imessage-mcp.listener", qos: .userInitiated)
    private let runningLock = NSLock()
    private var running = false

    public init(path: String) {
        self.path = path
    }

    public func start(onAccept: @escaping @Sendable (SocketLineConnection) -> Void) throws {
        unlink(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.system("socket", errno) }
        fd = descriptor
        var (address, length) = try socketAddress(path: path)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixSocketError.system("listen", code)
        }
        runningLock.withLock { running = true }
        queue.async { [weak self, descriptor] in
            guard let self else { return }
            while self.runningLock.withLock({ self.running }) {
                let clientFD = Darwin.accept(descriptor, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }
                do {
                    onAccept(try SocketLineConnection(
                        fd: clientFD,
                        sendTimeout: SocketLineConnection.defaultSendTimeout
                    ))
                } catch {
                    // SocketLineConnection closes the accepted descriptor if setup fails.
                    continue
                }
            }
        }
    }

    public func stop() {
        runningLock.withLock { running = false }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        unlink(path)
    }

    deinit { stop() }
}

public enum UnixSocketClient {
    public static func connect(path: String) throws -> SocketLineConnection {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        var (address, length) = try socketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("connect", code)
        }
        return try SocketLineConnection(
            fd: fd,
            sendTimeout: SocketLineConnection.defaultSendTimeout
        )
    }
}
