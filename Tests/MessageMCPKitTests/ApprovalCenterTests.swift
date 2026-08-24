import Foundation
import Testing
@testable import MessageMCPKit

private final class LockedDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?
    var value: Bool? { lock.withLock { storage } }
    func set(_ value: Bool) { lock.withLock { storage = value } }
}

private final class ApprovalSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var counts: [Int] = []

    func begin() -> Int {
        lock.withLock {
            defer { starts += 1 }
            return starts
        }
    }

    func record(_ count: Int) {
        lock.withLock { counts.append(count) }
    }

    var values: [Int] { lock.withLock { counts } }
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
            decision.set((try? center.requestApproval(
                kind: .send,
                title: "Send?",
                detail: "chat 1",
                timeout: 2,
                cancellation: nil
            )) ?? false)
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
    func timeout() throws {
        let center = ApprovalCenter()
        let decision = try center.requestApproval(
            kind: .reaction,
            title: "React?",
            detail: "chat 2",
            timeout: 0.01,
            cancellation: nil
        )
        #expect(decision == false)
        #expect(center.requests.isEmpty)
    }

    @Test("client cancellation revokes and removes a pending approval")
    func cancellation() throws {
        let center = ApprovalCenter()
        let cancellation = ToolCallCancellation()
        let appeared = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let decision = LockedDecision()
        center.onChange = { requests in
            if !requests.isEmpty { appeared.signal() }
        }
        DispatchQueue.global().async {
            decision.set((try? center.requestApproval(
                kind: .send,
                title: "Send?",
                detail: "exact intent",
                timeout: 2,
                cancellation: cancellation
            )) ?? false)
            finished.signal()
        }

        #expect(appeared.wait(timeout: .now() + 1) == .success)
        cancellation.cancel()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(decision.value == false)
        #expect(center.requests.isEmpty)
    }

    @Test("pending approvals have an explicit global capacity")
    func pendingApprovalBackpressure() throws {
        let center = ApprovalCenter(maximumPendingApprovals: 1)
        let appeared = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        center.onChange = { requests in
            if !requests.isEmpty { appeared.signal() }
        }
        DispatchQueue.global().async {
            _ = try? center.requestApproval(
                kind: .send,
                title: "First",
                detail: "first intent",
                timeout: 2,
                cancellation: nil
            )
            finished.signal()
        }
        #expect(appeared.wait(timeout: .now() + 1) == .success)

        #expect(throws: ToolServiceError.self) {
            try center.requestApproval(
                kind: .send,
                title: "Second",
                detail: "second intent",
                timeout: 0.1,
                cancellation: nil
            )
        }
        center.denyAll()
        #expect(finished.wait(timeout: .now() + 1) == .success)
    }

    @Test("approval snapshots are delivered in mutation order")
    func publicationOrdering() throws {
        let center = ApprovalCenter(maximumPendingApprovals: 4)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let recorder = ApprovalSnapshotRecorder()
        center.onChange = { requests in
            let index = recorder.begin()
            if index == 0 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 1)
            }
            recorder.record(requests.count)
        }

        let requests = DispatchGroup()
        for title in ["First", "Second"] {
            requests.enter()
            DispatchQueue.global().async {
                _ = try? center.requestApproval(
                    kind: .send,
                    title: title,
                    detail: "intent",
                    timeout: 2,
                    cancellation: nil
                )
                requests.leave()
            }
            if title == "First" {
                #expect(firstStarted.wait(timeout: .now() + 1) == .success)
            }
        }

        let deadline = Date().addingTimeInterval(1)
        while center.requests.count < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(center.requests.count == 2)
        releaseFirst.signal()
        center.waitForPublications()
        #expect(Array(recorder.values.prefix(2)) == [1, 2])

        center.denyAll()
        #expect(requests.wait(timeout: .now() + 1) == .success)
        center.waitForPublications()
    }
}
