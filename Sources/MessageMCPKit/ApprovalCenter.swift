import Foundation

public protocol ApprovalProviding: Sendable {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval
    ) -> Bool
}

public final class ApprovalCenter: ApprovalProviding, @unchecked Sendable {
    private struct Pending {
        let request: ApprovalRequest
        let semaphore: DispatchSemaphore
        var decision: Bool?
    }

    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    public var onChange: (([ApprovalRequest]) -> Void)?

    public init() {}

    public var requests: [ApprovalRequest] {
        lock.withLock {
            pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval = 120
    ) -> Bool {
        let createdAt = Date()
        let request = ApprovalRequest(
            kind: kind,
            title: title,
            detail: detail,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(timeout)
        )
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock {
            pending[request.id] = Pending(request: request, semaphore: semaphore, decision: nil)
        }
        publish()
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        let decision = lock.withLock { () -> Bool in
            let value = pending.removeValue(forKey: request.id)?.decision ?? false
            return waitResult == .success && value
        }
        publish()
        return decision
    }

    public func resolve(id: UUID, approved: Bool) {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            guard var item = pending[id] else { return nil }
            item.decision = approved
            pending[id] = item
            return item.semaphore
        }
        semaphore?.signal()
    }

    public func denyAll() {
        let semaphores = lock.withLock { () -> [DispatchSemaphore] in
            pending = pending.mapValues { item in
                var copy = item
                copy.decision = false
                return copy
            }
            return pending.values.map(\.semaphore)
        }
        semaphores.forEach { $0.signal() }
    }

    private func publish() {
        onChange?(requests)
    }
}

public struct AlwaysApprove: ApprovalProviding {
    public init() {}
    public func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval
    ) -> Bool { true }
}

public struct AlwaysDeny: ApprovalProviding {
    public init() {}
    public func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval
    ) -> Bool { false }
}
