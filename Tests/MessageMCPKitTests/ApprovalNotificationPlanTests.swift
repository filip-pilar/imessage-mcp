import Testing
@testable import MessageMCPKit

@Suite("Approval notification batching")
struct ApprovalNotificationPlanTests {
    @Test("alerts immediately when approvals transition from zero to one")
    func firstApproval() {
        var plan = ApprovalNotificationPlan()
        #expect(plan.update(pendingCount: 0, enabled: true) == .none)
        #expect(plan.update(pendingCount: 1, enabled: true) == .deliverImmediately(count: 1))
    }

    @Test("batches later count changes and clears when resolved")
    func laterApprovals() {
        var plan = ApprovalNotificationPlan()
        #expect(plan.update(pendingCount: 1, enabled: true) == .deliverImmediately(count: 1))
        #expect(plan.update(pendingCount: 2, enabled: true) == .scheduleBatchedUpdate(count: 2))
        #expect(plan.update(pendingCount: 4, enabled: true) == .scheduleBatchedUpdate(count: 4))
        #expect(plan.update(pendingCount: 4, enabled: true) == .none)
        #expect(plan.update(pendingCount: 0, enabled: true) == .clear)
    }

    @Test("enabling while an approval waits alerts immediately")
    func enableWhilePending() {
        var plan = ApprovalNotificationPlan()
        #expect(plan.update(pendingCount: 2, enabled: false) == .none)
        #expect(plan.update(pendingCount: 2, enabled: true) == .deliverImmediately(count: 2))
        #expect(plan.update(pendingCount: 2, enabled: false) == .clear)
    }
}
