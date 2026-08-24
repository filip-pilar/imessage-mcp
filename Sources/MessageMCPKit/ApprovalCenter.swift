import Foundation

public protocol ApprovalProviding: Sendable {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval
    ) -> Bool
}

public protocol CancellationAwareApprovalProviding: ApprovalProviding {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval,
        cancellation: ToolCallCancellation?
    ) throws -> Bool
}

public extension ApprovalProviding {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval,
        cancellation: ToolCallCancellation?
    ) throws -> Bool {
        guard cancellation?.isCancelled != true else { return false }
        if let provider = self as? any CancellationAwareApprovalProviding {
            return try provider.requestApproval(
                kind: kind,
                title: title,
                detail: detail,
                timeout: timeout,
                cancellation: cancellation
            )
        }
        return requestApproval(
            kind: kind,
            title: title,
            detail: detail,
            timeout: timeout
        )
    }
}

public extension CancellationAwareApprovalProviding {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval
    ) -> Bool {
        (try? requestApproval(
            kind: kind,
            title: title,
            detail: detail,
            timeout: timeout,
            cancellation: nil
        )) ?? false
    }
}

public final class ApprovalCenter: CancellationAwareApprovalProviding, @unchecked Sendable {
    private struct Pending {
        let request: ApprovalRequest
        let semaphore: DispatchSemaphore
        var decision: Bool?
    }

    private let lock = NSLock()
    private let maximumPendingApprovals: Int
    private let publicationQueue = DispatchQueue(
        label: "com.openai.imessage-mcp.approval-publications"
    )
    private var pending: [UUID: Pending] = [:]
    private var onChangeStorage: (([ApprovalRequest]) -> Void)?

    public init(maximumPendingApprovals: Int = 8) {
        self.maximumPendingApprovals = max(1, maximumPendingApprovals)
    }

    public var onChange: (([ApprovalRequest]) -> Void)? {
        get { lock.withLock { onChangeStorage } }
        set { lock.withLock { onChangeStorage = newValue } }
    }

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
        (try? requestApproval(
            kind: kind,
            title: title,
            detail: detail,
            timeout: timeout,
            cancellation: nil
        )) ?? false
    }

    public func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval,
        cancellation: ToolCallCancellation?
    ) throws -> Bool {
        guard cancellation?.isCancelled != true else { return false }
        let createdAt = Date()
        let request = ApprovalRequest(
            kind: kind,
            title: title,
            detail: detail,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(timeout)
        )
        let semaphore = DispatchSemaphore(value: 0)
        let inserted = lock.withLock { () -> Bool in
            guard pending.count < maximumPendingApprovals else { return false }
            pending[request.id] = Pending(request: request, semaphore: semaphore, decision: nil)
            return true
        }
        guard inserted else {
            throw ToolServiceError.disabled(
                "Too many writes are waiting for approval. Resolve an existing prompt and retry."
            )
        }
        let cancellationObserver = cancellation?.observe { [weak self] in
            self?.resolve(id: request.id, approved: false)
        }
        publish()
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        cancellation?.removeObserver(cancellationObserver)
        let decision = lock.withLock { () -> Bool in
            let value = pending.removeValue(forKey: request.id)?.decision ?? false
            return waitResult == .success && value
        }
        publish()
        return decision
    }

    public func resolve(id: UUID, approved: Bool) {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            guard var item = pending[id], item.decision == nil else { return nil }
            item.decision = approved
            pending[id] = item
            return item.semaphore
        }
        semaphore?.signal()
    }

    public func denyAll() {
        let semaphores = lock.withLock { () -> [DispatchSemaphore] in
            var values: [DispatchSemaphore] = []
            let unresolvedIDs = pending.compactMap { key, value in
                value.decision == nil ? key : nil
            }
            for id in unresolvedIDs {
                guard var item = pending[id] else { continue }
                item.decision = false
                pending[id] = item
                values.append(item.semaphore)
            }
            return values
        }
        semaphores.forEach { $0.signal() }
    }

    private func publish() {
        lock.withLock {
            let snapshot = pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
            publicationQueue.async { [weak self] in
                guard let self else { return }
                let callback = self.lock.withLock { self.onChangeStorage }
                callback?(snapshot)
            }
        }
    }

    func waitForPublications() {
        publicationQueue.sync {}
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
