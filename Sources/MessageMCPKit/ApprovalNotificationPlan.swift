public struct ApprovalNotificationPlan: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case deliverImmediately(count: Int)
        case scheduleBatchedUpdate(count: Int)
        case clear
    }

    private var pendingCount = 0
    private var notificationsEnabled = false

    public init() {}

    public mutating func update(pendingCount rawCount: Int, enabled: Bool) -> Action {
        let count = max(0, rawCount)
        let previousCount = pendingCount
        let wasEnabled = notificationsEnabled
        pendingCount = count
        notificationsEnabled = enabled

        guard enabled else {
            return wasEnabled ? .clear : .none
        }
        guard wasEnabled else {
            return count > 0 ? .deliverImmediately(count: count) : .none
        }
        guard count > 0 else {
            return previousCount > 0 ? .clear : .none
        }
        if previousCount == 0 {
            return .deliverImmediately(count: count)
        }
        if previousCount != count {
            return .scheduleBatchedUpdate(count: count)
        }
        return .none
    }
}
