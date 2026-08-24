import Foundation

public final class ToolCallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            guard !cancelled else { return [] }
            cancelled = true
            let values = Array(observers.values)
            observers.removeAll()
            return values
        }
        callbacks.forEach { $0() }
    }

    @discardableResult
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID? {
        let id = UUID()
        let invokeImmediately = lock.withLock { () -> Bool in
            guard !cancelled else { return true }
            observers[id] = callback
            return false
        }
        if invokeImmediately {
            callback()
            return nil
        }
        return id
    }

    public func removeObserver(_ id: UUID?) {
        guard let id else { return }
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }
}

public struct ToolCallContext: Sendable {
    public let cancellation: ToolCallCancellation?

    public init(cancellation: ToolCallCancellation? = nil) {
        self.cancellation = cancellation
    }

    public var isCancelled: Bool {
        cancellation?.isCancelled == true
    }

    public func ensureActive() throws {
        if isCancelled {
            throw ToolServiceError.disabled("The request was cancelled by the MCP client.")
        }
    }
}
