import AppKit
import ApplicationServices
import Foundation
import MessageMCPKit
import ServiceManagement
import SwiftUI

enum AutomationAccessState: String, Sendable {
    case allowed
    case denied
    case notRequested = "not_requested"
    case unavailable

    var label: String {
        switch self {
        case .allowed: return "Ready"
        case .denied: return "Needs access"
        case .notRequested: return "Asked on first use"
        case .unavailable: return "Not checked"
        }
    }

    var color: Color {
        switch self {
        case .allowed: return .green
        case .denied: return .orange
        case .notRequested, .unavailable: return .secondary
        }
    }
}

enum WritePolicyPreset: String, CaseIterable, Identifiable {
    case readOnly
    case confirmEveryWrite
    case allowWithoutAsking
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .readOnly: return "Read Only"
        case .confirmEveryWrite: return "Ask Before Writes"
        case .allowWithoutAsking: return "Allow Without Asking"
        case .custom: return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .readOnly: return "Clients can read Messages but cannot send or react."
        case .confirmEveryWrite: return "Approve every message and tapback in the menu."
        case .allowWithoutAsking: return "Trusted clients can send and react immediately."
        case .custom: return "Send and tapback confirmations are configured separately."
        }
    }
}

private final class RuntimeStatusStore: @unchecked Sendable {
    struct State {
        var brokerRunning = false
        var databaseReady = false
        var accessibilityReady = false
        var messagesAutomation = AutomationAccessState.unavailable
        var systemEventsAutomation = AutomationAccessState.unavailable
        var liveEventsRunning = false
        var clients: [MCPClientStatus] = []
        var lastClientConnectedAt: Date?
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ transform: (inout State) -> Void) {
        lock.withLock { transform(&state) }
    }

    func jsonObject(settings: AppSettings, latestEventCursor: String) -> [String: Any] {
        let current = lock.withLock { state }
        let formatter = ISO8601DateFormatter()
        var result: [String: Any] = [
            "broker_running": current.brokerRunning,
            "database_ready": current.databaseReady,
            "accessibility_ready": current.accessibilityReady,
            "messages_automation": current.messagesAutomation.rawValue,
            "system_events_automation": current.systemEventsAutomation.rawValue,
            "live_events_enabled": settings.liveEventsEnabled,
            "live_events_running": current.liveEventsRunning,
            "active_client_count": current.clients.count,
            "clients": current.clients.map {
                [
                    "name": $0.name,
                    "connected_at": formatter.string(from: $0.connectedAt),
                    "initialized": $0.initialized,
                ] as [String: Any]
            },
            "writes_enabled": settings.writesEnabled,
            "confirm_sends": settings.confirmSends,
            "confirm_reactions": settings.confirmReactions,
            "latest_event_cursor": latestEventCursor,
            "sip_enabled_mode": true,
        ]
        if let lastClientConnectedAt = current.lastClientConnectedAt {
            result["last_client_connected_at"] = formatter.string(from: lastClientConnectedAt)
        }
        return result
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var brokerRunning = false
    @Published var liveEventsRunning = false
    @Published var clients: [MCPClientStatus] = []
    @Published var lastClientConnectedAt: Date?
    @Published var databaseAccess: CheckState = .checking
    @Published var accessibilityAccess = AXIsProcessTrusted()
    @Published var messagesAutomationAccess = AutomationAccessState.unavailable
    @Published var systemEventsAutomationAccess = AutomationAccessState.unavailable
    @Published var launchAtLoginEnabled = false
    @Published var imsgVersion = "Checking…"
    @Published var statusMessage = "Starting…"
    @Published var settings: AppSettings
    @Published var activities: [ActivityEntry] = []
    @Published var approvals: [ApprovalRequest] = []
    @Published var diagnosticError: String?
    @Published var watcherError: String?
    @Published var actionError: String?

    var lastError: String? {
        actionError ?? watcherError ?? diagnosticError
    }

    var clientCount: Int { clients.count }

    var writePolicyPreset: WritePolicyPreset {
        guard settings.writesEnabled else { return .readOnly }
        if settings.confirmSends && settings.confirmReactions {
            return .confirmEveryWrite
        }
        if !settings.confirmSends && !settings.confirmReactions {
            return .allowWithoutAsking
        }
        return .custom
    }

    enum CheckState: Equatable {
        case checking
        case granted
        case missing(String)

        var label: String {
            switch self {
            case .checking: return "Checking"
            case .granted: return "Ready"
            case .missing: return "Needs access"
            }
        }

        var color: Color {
            switch self {
            case .checking: return .secondary
            case .granted: return .green
            case .missing: return .orange
            }
        }
    }

    private let settingsStore = SettingsStore()
    private let activityStore = ActivityStore()
    private let eventStore = EventStore()
    private let approvalCenter = ApprovalCenter()
    private let runtimeStatus = RuntimeStatusStore()
    private var broker: BrokerServer?
    private var watcher: WatchService?
    private var runner: IMsgRunner?
    private var token = ""
    private var announcedClientIDs: Set<UUID> = []

    init() {
        settings = settingsStore.value
        activities = activityStore.recent
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        activityStore.onChange = { [weak self] entries in
            DispatchQueue.main.async {
                self?.activities = entries
                if let latest = entries.first,
                   latest.succeeded,
                   latest.kind == .send || latest.kind == .reaction {
                    self?.refreshPermissionState()
                }
            }
        }
        approvalCenter.onChange = { [weak self] requests in
            DispatchQueue.main.async {
                self?.approvals = requests
                if !requests.isEmpty {
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
        }
    }

    func start() {
        do {
            try AppPaths.ensureDirectories()
            let imsgURL = try resolveIMsgURL()
            let runner = IMsgRunner(executableURL: imsgURL)
            self.runner = runner
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")

            let tools = ToolService(
                runner: runner,
                settings: settingsStore,
                activity: activityStore,
                events: eventStore,
                approvals: approvalCenter,
                statusProvider: { [weak self] in
                    self?.statusObject() ?? [:]
                }
            )
            let processor = MCPProcessor(tools: tools) { [weak self] in
                self?.statusObject() ?? [:]
            }
            let broker = BrokerServer(socketPath: AppPaths.socketPath, token: token, processor: processor)
            broker.onClientsChanged = { [weak self, runtimeStatus] clients in
                DispatchQueue.main.async {
                    guard let self else { return }
                    runtimeStatus.update {
                        $0.clients = clients
                        if let newest = clients.max(by: { $0.connectedAt < $1.connectedAt }) {
                            $0.lastClientConnectedAt = max(
                                $0.lastClientConnectedAt ?? .distantPast,
                                newest.connectedAt
                            )
                        }
                    }
                    self.clients = clients
                    if let newest = clients.max(by: { $0.connectedAt < $1.connectedAt }) {
                        self.lastClientConnectedAt = max(
                            self.lastClientConnectedAt ?? .distantPast,
                            newest.connectedAt
                        )
                    }
                    let newlyInitialized = clients.filter {
                        $0.initialized && !self.announcedClientIDs.contains($0.id)
                    }
                    self.announcedClientIDs.formUnion(newlyInitialized.map(\.id))
                    for client in newlyInitialized {
                        self.activityStore.append(ActivityEntry(
                            kind: .diagnostic,
                            title: "MCP client connected",
                            detail: client.name
                        ))
                    }
                    self.syncClientRuntimeStatus()
                }
            }
            try broker.start()
            self.broker = broker
            brokerRunning = true
            runtimeStatus.update { $0.brokerRunning = true }
            try writeConnectionInfo()

            eventStore.onEvent = { [weak broker] _ in broker?.notifyEvent() }
            let watcher = WatchService(executableURL: imsgURL, eventStore: eventStore, activity: activityStore)
            watcher.onStateChanged = { [weak self, runtimeStatus] running, error in
                runtimeStatus.update { $0.liveEventsRunning = running }
                DispatchQueue.main.async {
                    self?.liveEventsRunning = running
                    self?.watcherError = error
                }
            }
            self.watcher = watcher
            refreshDiagnostics()
        } catch {
            diagnosticError = error.localizedDescription
            statusMessage = "Setup required"
            databaseAccess = .missing(error.localizedDescription)
            runtimeStatus.update {
                $0.brokerRunning = false
                $0.databaseReady = false
            }
            activityStore.append(ActivityEntry(
                kind: .error,
                title: "App failed to start",
                detail: error.localizedDescription,
                succeeded: false
            ))
        }
    }

    func stop() {
        approvalCenter.denyAll()
        watcher?.stop()
        broker?.stop()
        brokerRunning = false
        clients = []
        runtimeStatus.update {
            $0.brokerRunning = false
            $0.clients = []
        }
        try? FileManager.default.removeItem(at: AppPaths.connectionFile)
    }

    func refreshDiagnostics() {
        refreshPermissionState()
        guard let runner else { return }
        statusMessage = "Checking Messages…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let version = try runner.run(arguments: ["--version"], timeout: 10)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let chats = try runner.run(
                    arguments: ["chats", "--limit", "200", "--json"],
                    timeout: 15
                ).jsonValue
                DispatchQueue.main.async {
                    self?.imsgVersion = version
                    self?.databaseAccess = .granted
                    self?.statusMessage = "Ready"
                    self?.diagnosticError = nil
                    self?.runtimeStatus.update { $0.databaseReady = true }
                    self?.watcher?.updateChatLabels(from: chats)
                    if self?.settings.liveEventsEnabled == true {
                        self?.watcher?.start()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.watcher?.stop()
                    self?.imsgVersion = (try? runner.run(arguments: ["--version"], timeout: 5)
                        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "Unavailable"
                    self?.databaseAccess = .missing(error.localizedDescription)
                    self?.statusMessage = "Permission needed"
                    self?.diagnosticError = error.localizedDescription
                    self?.runtimeStatus.update { $0.databaseReady = false }
                }
            }
        }
    }

    func refreshPermissionState() {
        accessibilityAccess = AXIsProcessTrusted()
        messagesAutomationAccess = automationAccess(bundleIdentifier: "com.apple.MobileSMS")
        systemEventsAutomationAccess = automationAccess(bundleIdentifier: "com.apple.systemevents")
        runtimeStatus.update {
            $0.accessibilityReady = accessibilityAccess
            $0.messagesAutomation = messagesAutomationAccess
            $0.systemEventsAutomation = systemEventsAutomationAccess
        }
        refreshLaunchAtLoginState()
    }

    func setWritePolicy(_ preset: WritePolicyPreset) {
        guard preset != .custom else { return }
        updateSettings {
            switch preset {
            case .readOnly:
                $0.writesEnabled = false
            case .confirmEveryWrite:
                $0.writesEnabled = true
                $0.confirmSends = true
                $0.confirmReactions = true
            case .allowWithoutAsking:
                $0.writesEnabled = true
                $0.confirmSends = false
                $0.confirmReactions = false
            case .custom:
                break
            }
        }
    }

    func setWritesEnabled(_ enabled: Bool) {
        updateSettings { $0.writesEnabled = enabled }
    }

    func setConfirmSends(_ enabled: Bool) {
        updateSettings { $0.confirmSends = enabled }
    }

    func setConfirmReactions(_ enabled: Bool) {
        updateSettings { $0.confirmReactions = enabled }
    }

    func setLiveEvents(_ enabled: Bool) {
        updateSettings { $0.liveEventsEnabled = enabled }
        if enabled && databaseAccess == .granted {
            watcher?.start()
        } else {
            watcher?.stop()
            if enabled {
                watcherError = "Grant Full Disk Access, then refresh diagnostics to start live updates."
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            updateSettings { $0.launchAtLogin = enabled }
            refreshLaunchAtLoginState()
            actionError = nil
        } catch {
            refreshLaunchAtLoginState()
            actionError = "Could not update Login Items: \(error.localizedDescription)"
        }
    }

    func approve(_ request: ApprovalRequest) {
        approvalCenter.resolve(id: request.id, approved: true)
    }

    func deny(_ request: ApprovalRequest) {
        approvalCenter.resolve(id: request.id, approved: false)
    }

    func openFullDiskAccess() {
        openPreference("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    func openAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissionState()
        openPreference("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openAutomation() {
        openPreference("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    func copyMCPCommand() {
        let proxy = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/imessage-mcp").path
        let escaped = proxy.replacingOccurrences(of: "'", with: "'\\''")
        let command = "codex mcp add imessage -- '\(escaped)'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        activityStore.append(ActivityEntry(
            kind: .diagnostic,
            title: "Codex command copied",
            detail: "Paste it into Terminal."
        ))
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func updateSettings(_ transform: (inout AppSettings) -> Void) {
        do {
            try settingsStore.update(transform)
            settings = settingsStore.value
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resolveIMsgURL() throws -> URL {
        let candidates: [URL?] = [
            settings.imsgOverridePath.map { URL(fileURLWithPath: $0) },
            ProcessInfo.processInfo.environment["IMSG_PATH"].map { URL(fileURLWithPath: $0) },
            Bundle.main.resourceURL?.appendingPathComponent("imsg/imsg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/imsg"),
            URL(fileURLWithPath: "/usr/local/bin/imsg"),
        ]
        for candidate in candidates.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw IMsgRunnerError.executableMissing(
            Bundle.main.resourceURL?.appendingPathComponent("imsg/imsg").path ?? "app resources"
        )
    }

    private func writeConnectionInfo() throws {
        let info = ConnectionInfo(
            socketPath: AppPaths.socketPath,
            token: token,
            appPID: ProcessInfo.processInfo.processIdentifier,
            version: MCPProcessor.serverVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: AppPaths.connectionFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.connectionFile.path
        )
    }

    nonisolated private func statusObject() -> [String: Any] {
        runtimeStatus.jsonObject(
            settings: settingsStore.value,
            latestEventCursor: eventStore.latestCursor.rawValue
        )
    }

    private func syncClientRuntimeStatus() {
        runtimeStatus.update {
            $0.clients = clients
            $0.lastClientConnectedAt = lastClientConnectedAt
        }
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        if settings.launchAtLogin != launchAtLoginEnabled {
            try? settingsStore.update { $0.launchAtLogin = launchAtLoginEnabled }
            settings = settingsStore.value
        }
    }

    private func openPreference(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

private func automationAccess(bundleIdentifier: String) -> AutomationAccessState {
    guard let identifierData = bundleIdentifier.data(using: .utf8) else {
        return .unavailable
    }
    var target = AEAddressDesc()
    let creationStatus = identifierData.withUnsafeBytes {
        AECreateDesc(
            DescType(typeApplicationBundleID),
            $0.baseAddress,
            identifierData.count,
            &target
        )
    }
    guard creationStatus == noErr else { return .unavailable }
    defer { AEDisposeDesc(&target) }
    let status = AEDeterminePermissionToAutomateTarget(
        &target,
        AEEventClass(kCoreEventClass),
        AEEventID(kAEOpenApplication),
        false
    )
    if status == noErr { return .allowed }
    if status == OSStatus(errAEEventNotPermitted) { return .denied }
    if status == OSStatus(errAEEventWouldRequireUserConsent) { return .notRequested }
    return .unavailable
}
