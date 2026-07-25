import Foundation

public final class WatchService: @unchecked Sendable {
    private let executableURL: URL
    private let eventStore: EventStore
    private let activity: ActivityStore
    private let stateLock = NSLock()
    private let chatLabelsLock = NSLock()
    private var process: Process?
    private var shouldRun = false
    private var chatLabels: [Int64: String] = [:]
    private let queue = DispatchQueue(label: "com.openai.imessage-mcp.watch", qos: .utility)
    public var onStateChanged: ((Bool, String?) -> Void)?

    public init(executableURL: URL, eventStore: EventStore, activity: ActivityStore) {
        self.executableURL = executableURL
        self.eventStore = eventStore
        self.activity = activity
    }

    public var isRunning: Bool {
        stateLock.withLock { process?.isRunning == true }
    }

    public func updateChatLabels(from value: Any) {
        let labels = Self.chatLabels(from: value)
        chatLabelsLock.withLock { chatLabels = labels }
    }

    public func start() {
        let startNeeded = stateLock.withLock { () -> Bool in
            guard !shouldRun else { return false }
            shouldRun = true
            return true
        }
        guard startNeeded else { return }
        queue.async { [weak self] in self?.runLoop() }
    }

    public func stop() {
        let current = stateLock.withLock { () -> Process? in
            shouldRun = false
            return process
        }
        current?.terminate()
        onStateChanged?(false, nil)
    }

    private func runLoop() {
        var retryDelay: TimeInterval = 1
        var lastLoggedFailure: String?
        while stateLock.withLock({ shouldRun }) {
            do {
                try runOnce()
                retryDelay = 1
            } catch {
                let message = error.localizedDescription
                if message != lastLoggedFailure {
                    activity.append(ActivityEntry(
                        kind: .error,
                        title: "Live updates paused",
                        detail: message,
                        succeeded: false
                    ))
                    lastLoggedFailure = message
                }
                onStateChanged?(false, message)
                guard stateLock.withLock({ shouldRun }) else { return }
                Thread.sleep(forTimeInterval: retryDelay)
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    private func runOnce() throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IMsgRunnerError.executableMissing(executableURL.path)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "watch", "--json", "--reactions", "--attachments", "--convert-attachments",
            "--debounce", "500ms",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let errorData = LockedWatchData()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
            errorRead.leave()
        }
        stateLock.withLock { self.process = process }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.closeFile()
            errorRead.wait()
            throw error
        }
        onStateChanged?(true, nil)

        try FileDescriptorLineReader.readLines(
            fileDescriptor: output.fileHandleForReading.fileDescriptor
        ) { line in
            guard let text = String(data: line, encoding: .utf8) else { return true }
            guard (try? JSONSerialization.jsonObject(with: line)) != nil else { return true }
            eventStore.append(payload: text)
            let labels = chatLabelsLock.withLock { chatLabels }
            activity.appendDebounced(Self.activityEntry(for: line, chatLabels: labels))
            return true
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        errorRead.wait()
        stateLock.withLock { self.process = nil }
        onStateChanged?(false, nil)
        if process.terminationStatus != 0 && stateLock.withLock({ shouldRun }) {
            let message = String(data: errorData.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw IMsgRunnerError.failed(
                status: process.terminationStatus,
                message: message?.isEmpty == false ? message! : "imsg watch exited unexpectedly."
            )
        }
    }

    static func activityEntry(
        for data: Data,
        chatLabels: [Int64: String]
    ) -> ActivityEntry {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ActivityEntry(
                kind: .event,
                title: "Messages activity",
                detail: "Message or reaction"
            )
        }
        let chatID = Self.int64(object["chat_id"])
        let eventLabel = Self.preferredLabel(in: object)
        let cachedLabel = chatID.flatMap { chatLabels[$0] }
        let chatLabel = eventLabel ?? cachedLabel
        let detail: String
        if let chatLabel, let chatID {
            detail = "\(chatLabel) · Chat \(chatID)"
        } else if let chatLabel {
            detail = chatLabel
        } else if let chatID {
            detail = "Chat \(chatID)"
        } else {
            detail = "Messages"
        }
        let title: String
        if object["is_reaction"] as? Bool == true {
            title = "New reaction"
        } else if object["is_from_me"] as? Bool == true {
            title = "Message sent"
        } else {
            title = "New message"
        }
        return ActivityEntry(kind: .event, title: title, detail: detail)
    }

    static func chatLabels(from value: Any) -> [Int64: String] {
        var result: [Int64: String] = [:]
        collectChatLabels(from: value, into: &result)
        return result
    }

    private static func collectChatLabels(from value: Any, into result: inout [Int64: String]) {
        if let object = value as? [String: Any] {
            if let chatID = int64(object["id"] ?? object["chat_id"]),
               let label = preferredLabel(in: object) {
                result[chatID] = label
            }
            for nested in object.values {
                collectChatLabels(from: nested, into: &result)
            }
        } else if let values = value as? [Any] {
            for nested in values {
                collectChatLabels(from: nested, into: &result)
            }
        }
    }

    private static func preferredLabel(in object: [String: Any]) -> String? {
        for key in ["display_name", "name", "contact_name"] {
            guard let raw = object[key] as? String else { continue }
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !label.hasPrefix("+"), !label.contains("@") else { continue }
            return label
        }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}

private final class LockedWatchData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data { lock.withLock { storage } }
    func set(_ data: Data) { lock.withLock { storage = data } }
}
