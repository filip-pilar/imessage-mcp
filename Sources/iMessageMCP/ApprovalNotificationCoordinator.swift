import Foundation
import MessageMCPKit
import UserNotifications

@MainActor
final class ApprovalNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private static let requestIdentifier = "com.forma.imessage-mcp.pending-approvals"
    nonisolated private static let updateMarker = "isBatchedUpdate"

    var onError: ((String) -> Void)?

    private let center: UNUserNotificationCenter
    private var plan = ApprovalNotificationPlan()
    private var pendingCount = 0
    private var updateTask: Task<Void, Never>?

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func update(pendingCount: Int, enabled: Bool) {
        self.pendingCount = max(0, pendingCount)
        switch plan.update(pendingCount: pendingCount, enabled: enabled) {
        case .none:
            break
        case let .deliverImmediately(count):
            updateTask?.cancel()
            deliver(count: count, isBatchedUpdate: false)
        case .scheduleBatchedUpdate:
            scheduleBatchedUpdate()
        case .clear:
            clear()
        }
    }

    func clear() {
        updateTask?.cancel()
        updateTask = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo[Self.updateMarker] as? Bool == true {
            return [.list]
        }
        return [.banner, .list, .sound]
    }

    private func scheduleBatchedUpdate() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let count = self.pendingCount
            guard count > 0 else { return }
            self.deliver(count: count, isBatchedUpdate: true)
        }
    }

    private func deliver(count: Int, isBatchedUpdate: Bool) {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "Approval required" : "Approvals required"
        content.body = count == 1
            ? "1 approval is waiting in iMessage MCP."
            : "\(count) approvals are waiting in iMessage MCP."
        content.threadIdentifier = "iMessage MCP approvals"
        // Batched requests reuse one identifier and update Notification Center quietly.
        content.interruptionLevel = isBatchedUpdate ? .passive : .active
        content.sound = isBatchedUpdate ? nil : .default
        content.userInfo = [Self.updateMarker: isBatchedUpdate]

        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier,
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.onError?("Could not show approval notification: \(error.localizedDescription)")
            }
        }
    }
}
