import Foundation
import Testing
@testable import MessageMCPKit

private final class LockedDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?
    var value: Bool? { lock.withLock { storage } }
    func set(_ value: Bool) { lock.withLock { storage = value } }
}

@Suite("Write approvals")
struct ApprovalCenterTests {
    @Test("resolves a pending action")
    func approve() throws {
        let center = ApprovalCenter()
        let appeared = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let decision = LockedDecision()
        center.onChange = { requests in
            if !requests.isEmpty { appeared.signal() }
        }
        DispatchQueue.global().async {
            decision.set(center.requestApproval(
                kind: .send,
                title: "Send?",
                detail: "chat 1",
                timeout: 2
            ))
            finished.signal()
        }
        #expect(appeared.wait(timeout: .now() + 1) == .success)
        let request = try #require(center.requests.first)
        #expect(request.expiresAt > request.createdAt)
        center.resolve(id: request.id, approved: true)
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(decision.value == true)
        #expect(center.requests.isEmpty)
    }

    @Test("times out closed")
    func timeout() {
        let center = ApprovalCenter()
        let decision = center.requestApproval(
            kind: .reaction,
            title: "React?",
            detail: "chat 2",
            timeout: 0.01
        )
        #expect(decision == false)
        #expect(center.requests.isEmpty)
    }
}
