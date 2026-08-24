import Foundation

public final class WatchService: @unchecked Sendable {
    private let executableURL: URL
    private let eventStore: EventStore
    private let activity: ActivityStore
    private let processEnvironment: [String: String]?
    private let stateLock = NSLock()
    private let transitionGate = NSRecursiveLock()
    private var process: Process?
    private var shouldRun = false
    private var runGeneration = UUID()
    private var stateRevision: UInt64 = 0
    private let queue = DispatchQueue(label: "com.openai.imessage-mcp.watch", qos: .utility)
    private let publicationQueue = DispatchQueue(
        label: "com.openai.imessage-mcp.watch-state-publications"
    )
    private var beforePublishingRunningStorage: (@Sendable (UUID) -> Void)?
    private var onStateChangedStorage: ((Bool, String?) -> Void)?

    var beforePublishingRunning: (@Sendable (UUID) -> Void)? {
        get { stateLock.withLock { beforePublishingRunningStorage } }
        set { stateLock.withLock { beforePublishingRunningStorage = newValue } }
    }

    public var onStateChanged: ((Bool, String?) -> Void)? {
        get { stateLock.withLock { onStateChangedStorage } }
        set { stateLock.withLock { onStateChangedStorage = newValue } }
    }

    public init(executableURL: URL, eventStore: EventStore, activity: ActivityStore) {
        self.executableURL = executableURL
        self.eventStore = eventStore
        self.activity = activity
        self.processEnvironment = nil
    }

    init(
        executableURL: URL,
        eventStore: EventStore,
        activity: ActivityStore,
        processEnvironment: [String: String]
    ) {
        self.executableURL = executableURL
        self.eventStore = eventStore
        self.activity = activity
        self.processEnvironment = processEnvironment
    }

    public var isRunning: Bool {
        stateLock.withLock { process?.isRunning == true }
    }

    @available(*, deprecated, message: "Activity history no longer retains conversation labels.")
    public func updateChatLabels(from value: Any) {
        // Kept as a source-compatible no-op. Retaining these labels would
        // conflict with the redacted activity-store boundary.
    }

    public func start() {
        let generation: UUID? = withTransitionGate {
            let transition = stateLock.withLock {
                () -> (generation: UUID, state: LiveEventWatcherState, revision: UInt64)? in
                guard !shouldRun else { return nil }
                shouldRun = true
                runGeneration = UUID()
                stateRevision &+= 1
                return (
                    runGeneration,
                    eventStore.beginWatcherGeneration(runGeneration),
                    stateRevision
                )
            }
            guard let transition else { return nil }
            enqueueStatePublication(
                running: false,
                error: nil,
                revision: transition.revision
            )
            enqueueInvalidationPublication(transition.state.latestCursor)
            return transition.generation
        }
        guard let generation else { return }
        queue.async { [weak self] in self?.runLoop(generation: generation) }
    }

    public func stop() {
        let transition = withTransitionGate {
            let transition = stateLock.withLock {
                () -> (
                    process: Process?,
                    state: LiveEventWatcherState?,
                    revision: UInt64?
                ) in
                let wasEnabled = shouldRun
                let generation = runGeneration
                shouldRun = false
                runGeneration = UUID()
                guard wasEnabled,
                    let state = eventStore.endWatcherGeneration(generation)
                else { return (process, nil, nil) }
                stateRevision &+= 1
                return (process, state, stateRevision)
            }
            if let revision = transition.revision,
                let state = transition.state
            {
                enqueueStatePublication(
                    running: false,
                    error: nil,
                    revision: revision
                )
                enqueueInvalidationPublication(state.latestCursor)
            }
            return transition
        }
        transition.process?.terminate()
    }

    private func runLoop(generation: UUID) {
        var retryDelay: TimeInterval = 1
        var lastLoggedFailure: String?
        while shouldContinue(generation) {
            do {
                try runOnce(generation: generation)
            } catch {
                let transition: (state: LiveEventWatcherState, revision: UInt64)? =
                    withTransitionGate {
                        let transition = stateLock.withLock {
                            () -> (state: LiveEventWatcherState, revision: UInt64)? in
                            guard shouldRun, runGeneration == generation,
                                let state = eventStore.breakWatcherContinuity(
                                    generation: generation
                                )
                            else { return nil }
                            stateRevision &+= 1
                            return (state, stateRevision)
                        }
                        guard let transition else { return nil }
                        enqueueStatePublication(
                            running: false,
                            error: error.localizedDescription,
                            revision: transition.revision
                        )
                        enqueueInvalidationPublication(transition.state.latestCursor)
                        return transition
                    }
                guard transition != nil else { return }
                let message = error.localizedDescription
                if message != lastLoggedFailure {
                    activity.append(kind: .error, succeeded: false)
                    lastLoggedFailure = message
                }
                guard shouldContinue(generation) else { return }
                Thread.sleep(forTimeInterval: retryDelay)
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    private func runOnce(generation: UUID) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IMsgRunnerError.executableMissing(executableURL.path)
        }
        guard shouldContinue(generation) else { return }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "watch", "--json", "--reactions", "--attachments", "--convert-attachments",
            "--debounce", "500ms",
        ]
        if let processEnvironment {
            process.environment = ProcessInfo.processInfo.environment.merging(
                processEnvironment,
                uniquingKeysWith: { _, override in override }
            )
        }
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
            stateLock.withLock {
                if self.process === process { self.process = nil }
            }
            throw error
        }
        guard shouldContinue(generation) else {
            process.terminate()
            process.waitUntilExit()
            errorRead.wait()
            stateLock.withLock {
                if self.process === process { self.process = nil }
            }
            return
        }
        beforePublishingRunning?(generation)
        let runningState = withTransitionGate {
            let transition = stateLock.withLock {
                () -> (sessionID: UUID, revision: UInt64)? in
                guard shouldRun, runGeneration == generation,
                    let state = eventStore.publishWatcherAvailable(generation: generation)
                else { return nil }
                stateRevision &+= 1
                return (state.latestCursor.sessionID, stateRevision)
            }
            if let transition {
                enqueueStatePublication(
                    running: true,
                    error: nil,
                    revision: transition.revision
                )
            }
            return transition
        }
        guard let runningState else {
            process.terminate()
            process.waitUntilExit()
            errorRead.wait()
            stateLock.withLock {
                if self.process === process { self.process = nil }
            }
            return
        }
        let eventGeneration = runningState.sessionID

        try FileDescriptorLineReader.readLines(
            fileDescriptor: output.fileHandleForReading.fileDescriptor
        ) { line in
            guard self.shouldContinue(generation) else { return false }
            guard let text = String(data: line, encoding: .utf8) else { return true }
            guard (try? JSONSerialization.jsonObject(with: line)) != nil else { return true }
            guard eventStore.append(payload: text, ifSessionID: eventGeneration) != nil else {
                return false
            }
            activity.appendDebounced(kind: .event)
            return true
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        errorRead.wait()
        stateLock.withLock {
            if self.process === process { self.process = nil }
        }
        guard shouldContinue(generation) else { return }
        if shouldContinue(generation) {
            let message = String(data: errorData.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw IMsgRunnerError.failed(
                status: process.terminationStatus,
                message: message?.isEmpty == false ? message! : "imsg watch exited unexpectedly."
            )
        }
    }

    private func shouldContinue(_ generation: UUID) -> Bool {
        stateLock.withLock { shouldRun && runGeneration == generation }
    }

    private func enqueueStatePublication(
        running: Bool,
        error: String?,
        revision: UInt64
    ) {
        publicationQueue.async { [weak self] in
            guard let self else { return }
            self.waitForTransitionBoundary()
            let callback = self.stateLock.withLock {
                self.stateRevision == revision
                    ? self.onStateChangedStorage
                    : nil
            }
            callback?(running, error)
        }
    }

    private func enqueueInvalidationPublication(_ cursor: LiveEventCursor) {
        publicationQueue.async { [weak self] in
            guard let self else { return }
            self.waitForTransitionBoundary()
            self.eventStore.publishInvalidation(cursor)
        }
    }

    private func waitForTransitionBoundary() {
        transitionGate.lock()
        transitionGate.unlock()
    }

    private func withTransitionGate<T>(_ operation: () throws -> T) rethrows -> T {
        transitionGate.lock()
        defer { transitionGate.unlock() }
        return try operation()
    }

    func waitForStatePublications() {
        publicationQueue.sync {}
    }
}

private final class LockedWatchData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data { lock.withLock { storage } }
    func set(_ data: Data) { lock.withLock { storage = data } }
}
