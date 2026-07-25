import Foundation
import MessageMCPKit

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func setTrue() { lock.withLock { storage = true } }
}

private func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func loadConnectionInfo() -> ConnectionInfo? {
    let file = ProcessInfo.processInfo.environment["IMESSAGE_MCP_CONNECTION_FILE"]
        .map { URL(fileURLWithPath: $0) } ?? AppPaths.connectionFile
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(ConnectionInfo.self, from: data)
}

private func menuAppURL() -> URL? {
    let executable = URL(
        fileURLWithPath: CommandLine.arguments[0],
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ).standardizedFileURL
    let bundleURL = executable
        .deletingLastPathComponent() // MacOS
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // .app
    if bundleURL.pathExtension == "app" { return bundleURL }

    let siblingBundle = executable
        .deletingLastPathComponent()
        .appendingPathComponent("iMessage MCP.app", isDirectory: true)
    guard FileManager.default.fileExists(atPath: siblingBundle.path) else { return nil }
    return siblingBundle
}

private func launchMenuApp() {
    guard let bundleURL = menuAppURL() else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [bundleURL.path]
    try? process.run()
    process.waitUntilExit()
}

private func connectWithRetry() throws -> (SocketLineConnection, ConnectionInfo) {
    var launched = false
    var lastError: Error = UnixSocketError.disconnected
    for _ in 0..<50 {
        if let info = loadConnectionInfo() {
            do {
                let connection = try UnixSocketClient.connect(path: info.socketPath)
                return (connection, info)
            } catch {
                lastError = error
            }
        }
        if !launched {
            launchMenuApp()
            launched = true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw lastError
}

do {
    let (connection, info) = try connectWithRetry()
    let hello = try JSONSerialization.data(withJSONObject: [
        "type": "hello",
        "token": info.token,
        "client": "stdio-proxy",
    ])
    try connection.writeLine(hello)

    let helloSemaphore = DispatchSemaphore(value: 0)
    let outputFinished = DispatchSemaphore(value: 0)
    let authenticated = LockedBool()
    let outputQueue = DispatchQueue(label: "com.openai.imessage-mcp.proxy.output")
    outputQueue.async {
        do {
            try connection.readLines { line in
                let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                let isAccepted = response?["type"] as? String == "hello"
                    && response?["ok"] as? Bool == true
                if response?["type"] as? String == "hello" {
                    if isAccepted { authenticated.setTrue() }
                    helloSemaphore.signal()
                    return isAccepted
                }
                FileHandle.standardOutput.write(line)
                FileHandle.standardOutput.write(Data([0x0A]))
                return true
            }
        } catch {
            writeStderr(error.localizedDescription)
        }
        helloSemaphore.signal()
        outputFinished.signal()
    }

    guard helloSemaphore.wait(timeout: .now() + 5) == .success,
          authenticated.value else {
        throw UnixSocketError.disconnected
    }

    try FileDescriptorLineReader.readLines { line in
        try connection.writeLine(line)
        return true
    }
    connection.finishWriting()
    _ = outputFinished.wait(timeout: .now() + 2)
    connection.shutdown()
} catch {
    writeStderr("iMessage MCP could not connect to its menu app: \(error.localizedDescription)")
    exit(1)
}
