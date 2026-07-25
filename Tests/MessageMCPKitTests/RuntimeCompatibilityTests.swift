import Testing
@testable import MessageMCPKit

@Suite("App and proxy compatibility")
struct RuntimeCompatibilityTests {
    private let info = ConnectionInfo(
        socketPath: "/tmp/test.sock",
        token: "token",
        appPID: 42,
        version: "1.4.2"
    )

    @Test("accepts matching semantic major versions")
    func matchingMajor() {
        #expect(RuntimeCompatibility.versionsAreCompatible(
            proxyVersion: "1.0.0",
            appVersion: "1.9.7"
        ))
        #expect(RuntimeCompatibility.versionsAreCompatible(
            proxyVersion: "2.0.0-beta.1",
            appVersion: "2.3.4"
        ))
        #expect(RuntimeCompatibility.versionsAreCompatible(
            proxyVersion: "3.0.0+codex.local",
            appVersion: "3.1.0-beta.2+build.4"
        ))
    }

    @Test("rejects incompatible or malformed versions")
    func incompatibleVersions() {
        #expect(!RuntimeCompatibility.versionsAreCompatible(
            proxyVersion: "1.0.0",
            appVersion: "2.0.0"
        ))
        #expect(!RuntimeCompatibility.versionsAreCompatible(
            proxyVersion: "development",
            appVersion: "1.0.0"
        ))
        #expect(!RuntimeCompatibility.versionsAreCompatible(
            proxyVersion: "1.0",
            appVersion: "1.0.0"
        ))
    }

    @Test("stale process wins before version compatibility")
    func staleProcess() {
        let readiness = RuntimeCompatibility.connectionReadiness(
            info,
            proxyVersion: "1.0.0",
            processIsRunning: { _ in false }
        )
        #expect(readiness == .staleProcess)
    }

    @Test("reports an incompatible running app")
    func incompatibleRunningApp() {
        let readiness = RuntimeCompatibility.connectionReadiness(
            info,
            proxyVersion: "2.0.0",
            processIsRunning: { $0 == 42 }
        )
        #expect(readiness == .incompatibleVersion)
    }
}
