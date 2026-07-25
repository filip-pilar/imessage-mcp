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
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IMsgRunnerError.executableMissing(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutData = LockedData()
        let stderrData = LockedData()
        let reads = DispatchGroup()
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutData.set(data)
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData.set(data)
            reads.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw IMsgRunnerError.timedOut
        }
        reads.wait()

        let stdout = String(data: stdoutData.value, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData.value, encoding: .utf8) ?? ""
        let output = CommandOutput(stdout: stdout, stderr: stderr, status: process.terminationStatus)
        guard output.status == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let requestData = try JSONSerialization.data(withJSONObject: request)

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IMsgRunnerError.executableMissing(executableURL.path)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["rpc"]
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(requestData)
        inputPipe.fileHandleForWriting.write(Data([0x0A]))
        inputPipe.fileHandleForWriting.closeFile()

        let stdoutData = LockedData()
        let stderrData = LockedData()
        let reads = DispatchGroup()
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutData.set(data)
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData.set(data)
            reads.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw IMsgRunnerError.timedOut
        }
        reads.wait()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData.value, encoding: .utf8) ?? "RPC failed."
            throw IMsgRunnerError.failed(status: process.terminationStatus, message: message)
        }
        guard
            let line = String(data: stdoutData.value, encoding: .utf8)?
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
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data { lock.withLock { storage } }
    func set(_ data: Data) { lock.withLock { storage = data } }
}
