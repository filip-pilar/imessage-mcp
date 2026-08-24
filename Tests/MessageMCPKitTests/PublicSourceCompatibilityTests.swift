import Darwin
import Foundation
import Testing
@testable import MessageMCPKit

private struct LegacyApprovalProvider: ApprovalProviding {
    func requestApproval(
        kind: ApprovalKind,
        title: String,
        detail: String,
        timeout: TimeInterval
    ) -> Bool { true }
}

private func legacyErrorMessage(_ error: ToolServiceError) -> String {
    switch error {
    case .invalid(let message), .disabled(let message):
        return message
    case .denied:
        return "denied"
    }
}

@Suite("MessageMCPKit 1.0 source compatibility")
struct PublicSourceCompatibilityTests {
    @Test("legacy exhaustive ToolServiceError switches remain source-compatible")
    func toolServiceErrorSurface() {
        #expect(legacyErrorMessage(.invalid("invalid")) == "invalid")
        #expect(legacyErrorMessage(.disabled("disabled")) == "disabled")
        #expect(legacyErrorMessage(.denied) == "denied")
    }

    @Test("legacy approval conformers and built-in decisions remain available")
    func approvalSurface() throws {
        let legacy: any ApprovalProviding = LegacyApprovalProvider()
        #expect(legacy.requestApproval(
            kind: .send,
            title: "title",
            detail: "detail",
            timeout: 0
        ))
        #expect(try legacy.requestApproval(
            kind: .send,
            title: "title",
            detail: "detail",
            timeout: 0,
            cancellation: nil
        ))
        #expect(MessageMCPKit.AlwaysApprove().requestApproval(
            kind: .send,
            title: "title",
            detail: "detail",
            timeout: 0
        ))
        #expect(!MessageMCPKit.AlwaysDeny().requestApproval(
            kind: .send,
            title: "title",
            detail: "detail",
            timeout: 0
        ))
        let center = ApprovalCenter()
        let legacyDefaultTimeoutCall: () -> Bool = {
            center.requestApproval(
                kind: .send,
                title: "title",
                detail: "detail"
            )
        }
        _ = legacyDefaultTimeoutCall
    }

    @Test("legacy settings, watcher label, and socket entry points still compile")
    func retainedEntryPoints() throws {
        var settings = AppSettings()
        settings.launchAtLogin = true
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.launchAtLogin)

        let environment = try TestEnvironment()
        let watcher = WatchService(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            eventStore: environment.events,
            activity: environment.activity
        )
        watcher.updateChatLabels(from: ["chat_id": 1, "display_name": "ignored"])

        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let connection = SocketLineConnection(fd: descriptors[0])
        defer { Darwin.close(descriptors[1]) }
        #expect(connection.fd == descriptors[0])
        var noSignal: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: noSignal))
        #expect(Darwin.getsockopt(
            connection.fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            &length
        ) == 0)
        #expect(noSignal == 1)
    }
}
