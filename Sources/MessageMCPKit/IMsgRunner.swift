import Darwin
import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32

    public init(stdout: String, stderr: String = "", status: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }

    public var jsonValue: Any {
        let lines = stdout.split(whereSeparator: \.isNewline).map(String.init)
        let values = lines.compactMap { line -> Any? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        if values.count == 1 {
            return values[0]
        }
        return values
    }
}

public enum IMsgRunnerError: LocalizedError, Equatable {
    case executableMissing(String)
    case timedOut
    case failed(status: Int32, message: String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "The bundled imsg executable is missing at \(path)."
        case .timedOut:
            return "imsg did not finish before the operation timed out."
        case .failed(_, let message):
            return message
        case .invalidOutput(let message):
            return "imsg returned invalid output: \(message)"
        }
    }
}

public protocol IMsgRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) throws -> CommandOutput
    func rpc(method: String, params: [String: Any], timeout: TimeInterval) throws -> Any
}

public final class IMsgRunner: IMsgRunning, @unchecked Sendable {
    public let executableURL: URL
    private let environment: [String: String]

    public init(executableURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executableURL = executableURL
        self.environment = environment
    }

    public func run(arguments: [String], timeout: TimeInterval = 30) throws -> CommandOutput {
        let execution = try execute(arguments: arguments, input: nil, timeout: timeout)
        let output = CommandOutput(
            stdout: String(data: execution.stdout, encoding: .utf8) ?? "",
            stderr: String(data: execution.stderr, encoding: .utf8) ?? "",
            status: execution.status
        )
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw IMsgRunnerError.failed(
                status: output.status,
                message: message.isEmpty ? "imsg exited with status \(output.status)." : message
            )
        }
        return output
    }

    public func rpc(
        method: String,
        params: [String: Any],
        timeout: TimeInterval = 30
    ) throws -> Any {
        guard JSONSerialization.isValidJSONObject(params) else {
            throw IMsgRunnerError.invalidOutput("RPC parameters are not valid JSON.")
        }
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        var requestData = try JSONSerialization.data(withJSONObject: request)
        requestData.append(0x0A)

        let output = try execute(arguments: ["rpc"], input: requestData, timeout: timeout)
        guard output.status == 0 else {
            throw IMsgRunnerError.failed(
                status: output.status,
                message: String(data: output.stderr, encoding: .utf8) ?? "RPC failed."
            )
        }
        guard
            let line = String(data: output.stdout, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first,
            let data = String(line).data(using: .utf8),
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw IMsgRunnerError.invalidOutput("No JSON-RPC response.")
        }
        if let error = response["error"] as? [String: Any] {
            throw IMsgRunnerError.failed(
                status: -1,
                message: error["message"] as? String ?? "Unknown imsg RPC error."
            )
        }
        guard let result = response["result"] else {
            throw IMsgRunnerError.invalidOutput("JSON-RPC response has no result.")
        }
        return result
    }

    private func execute(arguments: [String], input: Data?, timeout: TimeInterval) throws -> SupervisedOutput {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IMsgRunnerError.executableMissing(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let inputPipe = input.map { _ in Pipe() }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let termination = TerminationObservation()
        process.terminationHandler = { _ in termination.markExited() }

        let inputHandle = inputPipe?.fileHandleForWriting
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let inputDescriptor = inputHandle?.fileDescriptor
        let stdoutDescriptor = stdoutHandle.fileDescriptor
        let stderrDescriptor = stderrHandle.fileDescriptor

        do {
            if let inputDescriptor {
                try configureNonblocking(inputDescriptor, suppressBrokenPipe: true)
            }
            try configureNonblocking(stdoutDescriptor)
            try configureNonblocking(stderrDescriptor)
        } catch {
            inputHandle?.closeFile()
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            throw error
        }

        let deadline = MonotonicDeadline(timeout: timeout)
        do {
            try process.run()
        } catch {
            inputHandle?.closeFile()
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            throw error
        }

        var inputOffset = 0
        var inputOpen = input != nil
        var stdoutOpen = true
        var stderrOpen = true
        var stdoutData = Data()
        var stderrData = Data()

        do {
            while true {
                guard !deadline.hasExpired else {
                    throw IMsgRunnerError.timedOut
                }

                try drain(stdoutDescriptor, into: &stdoutData, isOpen: &stdoutOpen, deadline: deadline)
                try drain(stderrDescriptor, into: &stderrData, isOpen: &stderrOpen, deadline: deadline)
                if let input, let inputDescriptor, inputOpen {
                    try deliver(
                        input,
                        through: inputDescriptor,
                        offset: &inputOffset,
                        isOpen: &inputOpen,
                        deadline: deadline
                    )
                    if !inputOpen {
                        inputHandle?.closeFile()
                    }
                }

                if termination.hasExited, inputOpen {
                    throw POSIXFailure(code: EPIPE)
                }
                if termination.hasExited, !inputOpen, !stdoutOpen, !stderrOpen {
                    stdoutHandle.closeFile()
                    stderrHandle.closeFile()
                    process.waitUntilExit()
                    return SupervisedOutput(
                        stdout: stdoutData,
                        stderr: stderrData,
                        status: process.terminationStatus
                    )
                }

                try waitForProgress(
                    inputDescriptor: inputOpen ? inputDescriptor : nil,
                    stdoutDescriptor: stdoutOpen ? stdoutDescriptor : nil,
                    stderrDescriptor: stderrOpen ? stderrDescriptor : nil,
                    deadline: deadline
                )
            }
        } catch {
            inputHandle?.closeFile()
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            terminateAndReap(process, termination: termination)
            throw error
        }
    }

    private func configureNonblocking(_ descriptor: Int32, suppressBrokenPipe: Bool = false) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXFailure(code: errno)
        }
        if suppressBrokenPipe, fcntl(descriptor, F_SETNOSIGPIPE, 1) == -1 {
            throw POSIXFailure(code: errno)
        }
    }

    private func drain(
        _ descriptor: Int32,
        into data: inout Data,
        isOpen: inout Bool,
        deadline: MonotonicDeadline
    ) throws {
        guard isOpen else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard !deadline.hasExpired else { throw IMsgRunnerError.timedOut }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                return
            } else if count == 0 {
                isOpen = false
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                throw POSIXFailure(code: errno)
            }
        }
    }

    private func deliver(
        _ data: Data,
        through descriptor: Int32,
        offset: inout Int,
        isOpen: inout Bool,
        deadline: MonotonicDeadline
    ) throws {
        guard isOpen else { return }
        while offset < data.count {
            guard !deadline.hasExpired else { throw IMsgRunnerError.timedOut }
            let length = min(data.count - offset, 64 * 1024)
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), length)
            }
            if count > 0 {
                offset += count
                if offset == data.count {
                    isOpen = false
                }
                return
            } else if count == -1, errno == EINTR {
                continue
            } else if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                throw POSIXFailure(code: count == -1 ? errno : EIO)
            }
        }
    }

    private func waitForProgress(
        inputDescriptor: Int32?,
        stdoutDescriptor: Int32?,
        stderrDescriptor: Int32?,
        deadline: MonotonicDeadline
    ) throws {
        var descriptors = [pollfd]()
        if let inputDescriptor {
            descriptors.append(pollfd(fd: inputDescriptor, events: Int16(POLLOUT), revents: 0))
        }
        if let stdoutDescriptor {
            descriptors.append(pollfd(fd: stdoutDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0))
        }
        if let stderrDescriptor {
            descriptors.append(pollfd(fd: stderrDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0))
        }
        let result = poll(&descriptors, nfds_t(descriptors.count), deadline.pollTimeoutMilliseconds)
        if result == -1, errno != EINTR {
            throw POSIXFailure(code: errno)
        }
    }

    private func terminateAndReap(_ process: Process, termination: TerminationObservation) {
        guard !termination.hasExited else {
            process.waitUntilExit()
            return
        }

        if process.isRunning {
            process.terminate()
        }
        let graceDeadline = MonotonicDeadline(timeout: 0.5)
        while !termination.hasExited, !graceDeadline.hasExpired {
            usleep(10_000)
        }
        if !termination.hasExited, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private struct SupervisedOutput {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

private final class TerminationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false

    var hasExited: Bool { lock.withLock { exited } }

    func markExited() {
        lock.withLock { exited = true }
    }
}

private struct MonotonicDeadline {
    private let uptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard timeout > 0, timeout.isFinite else {
            uptimeNanoseconds = timeout == .infinity ? UInt64.max : now
            return
        }
        let nanoseconds = timeout * 1_000_000_000
        if nanoseconds >= Double(UInt64.max - now) {
            uptimeNanoseconds = UInt64.max
        } else {
            uptimeNanoseconds = now + UInt64(nanoseconds)
        }
    }

    var hasExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= uptimeNanoseconds
    }

    var pollTimeoutMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else { return 0 }
        let remainingMilliseconds = (uptimeNanoseconds - now + 999_999) / 1_000_000
        return Int32(min(remainingMilliseconds, 50))
    }
}

private struct POSIXFailure: Error {
    let code: Int32
}
