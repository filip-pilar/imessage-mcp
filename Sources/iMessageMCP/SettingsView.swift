import AppKit
import MessageMCPKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(model)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            PermissionsSettingsView()
                .environmentObject(model)
                .tabItem {
                    Label("Permissions", systemImage: "hand.raised")
                }

            ActivitySettingsView()
                .environmentObject(model)
                .tabItem {
                    Label("Activity", systemImage: "clock")
                }
        }
        .frame(width: 580, height: 500)
        .onAppear {
            model.refreshPermissionState()
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader(
                    "General",
                    detail: "Control how trusted MCP clients interact with Messages."
                )

                GroupBox("Write Access") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(
                            "Mode",
                            selection: Binding(
                                get: { model.writePolicyPreset },
                                set: { model.setWritePolicy($0) }
                            )
                        ) {
                            Text(WritePolicyPreset.readOnly.title).tag(WritePolicyPreset.readOnly)
                            Text(WritePolicyPreset.confirmEveryWrite.title).tag(WritePolicyPreset.confirmEveryWrite)
                            Text(WritePolicyPreset.allowWithoutAsking.title).tag(WritePolicyPreset.allowWithoutAsking)
                            if model.writePolicyPreset == .custom {
                                Text(WritePolicyPreset.custom.title).tag(WritePolicyPreset.custom)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text(model.writePolicyPreset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle(
                            "Ask before each message",
                            isOn: Binding(
                                get: { model.settings.confirmSends },
                                set: { model.setConfirmSends($0) }
                            )
                        )
                        .disabled(!model.settings.writesEnabled)

                        Toggle(
                            "Ask before each tapback",
                            isOn: Binding(
                                get: { model.settings.confirmReactions },
                                set: { model.setConfirmReactions($0) }
                            )
                        )
                        .disabled(!model.settings.writesEnabled)
                    }
                    .padding(8)
                }

                GroupBox("Background Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Live message updates",
                            isOn: Binding(
                                get: { model.settings.liveEventsEnabled },
                                set: { model.setLiveEvents($0) }
                            )
                        )
                        Text("Keeps an in-memory cursor of new messages and reactions while the app is running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle(
                            "Open at login",
                            isOn: Binding(
                                get: { model.launchAtLoginEnabled },
                                set: { model.setLaunchAtLogin($0) }
                            )
                        )
                        Text("Recommended when you want live updates available after restarting your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Codex Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Active MCP sessions", systemImage: "bolt.horizontal.fill")
                            Spacer()
                            Text(connectionSummary)
                                .foregroundStyle(model.clientCount > 0 ? Color.green : Color.secondary)
                        }

                        if let lastConnected = model.lastClientConnectedAt {
                            HStack {
                                Text("Last connected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(lastConnected, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Codex starts the local proxy on demand. An idle configured client can correctly show no active session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Copy Setup Command", action: model.copyMCPCommand)
                            Button("Reveal App…", action: model.revealApp)
                            Spacer()
                            Button("Refresh Diagnostics", action: model.refreshDiagnostics)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(22)
        }
    }

    private var connectionSummary: String {
        if model.clientCount == 1, let client = model.clients.first {
            return client.name
        }
        if model.clientCount > 1 {
            return "\(model.clientCount) connected"
        }
        return "Connects on demand"
    }
}

private struct PermissionsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader(
                    "Permissions",
                    detail: "macOS grants permissions to this exact signed build. Rebuilding can require granting them again."
                )

                GroupBox("Read Messages") {
                    permissionRow(
                        title: "Full Disk Access",
                        detail: "Allows read-only access to your local Messages database.",
                        status: model.databaseAccess == .granted ? "Ready" : "Needs access",
                        color: model.databaseAccess == .granted ? .green : .orange,
                        button: model.databaseAccess == .granted ? "Open Settings…" : "Grant Access…",
                        action: model.openFullDiskAccess
                    )
                    .padding(8)
                }

                GroupBox("Send Messages") {
                    permissionRow(
                        title: "Messages control",
                        detail: "macOS normally asks once on the first send. You can revoke access in Privacy & Security → Automation.",
                        status: model.messagesAutomationAccess.label,
                        color: model.messagesAutomationAccess.color,
                        button: "Open Settings…",
                        action: model.openAutomation
                    )
                    .padding(8)
                }

                GroupBox("Send Tapbacks") {
                    VStack(spacing: 0) {
                        permissionRow(
                            title: "Accessibility",
                            detail: "Lets the app select and verify the latest incoming message in Messages.",
                            status: model.accessibilityAccess ? "Ready" : "Needs access",
                            color: model.accessibilityAccess ? .green : .orange,
                            button: model.accessibilityAccess ? "Open Settings…" : "Grant Access…",
                            action: model.openAccessibility
                        )

                        Divider().padding(.vertical, 10)

                        permissionRow(
                            title: "System Events control",
                            detail: "macOS can ask separately on the first tapback.",
                            status: model.systemEventsAutomationAccess.label,
                            color: model.systemEventsAutomationAccess.color,
                            button: "Open Settings…",
                            action: model.openAutomation
                        )
                    }
                    .padding(8)
                }

                HStack {
                    Spacer()
                    Button("Refresh Permission Status", action: model.refreshPermissionState)
                }
            }
            .padding(22)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        status: String,
        color: Color,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: color == .green ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.10), in: Capsule())
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action)
                .fixedSize()
        }
    }
}

private struct ActivitySettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                "Activity",
                detail: "Local operation metadata. Message bodies are never stored here."
            )

            ActivityList(entries: Array(model.activities.prefix(100)))
        }
        .padding(22)
    }
}

private struct ActivityList: View {
    let entries: [ActivityEntry]

    var body: some View {
        GroupBox {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock",
                    description: Text("MCP reads, sends, tapbacks, and diagnostics will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.succeeded ? icon(for: entry.kind) : "exclamationmark.triangle")
                                    .foregroundStyle(entry.succeeded ? Color.secondary : Color.orange)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .lineLimit(1)
                                    Text(entry.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .help(entry.detail)
                                }
                                Spacer()
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 7)
                            if index < entries.count - 1 {
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func icon(for kind: ActivityKind) -> String {
        switch kind {
        case .read: return "book"
        case .send: return "paperplane"
        case .reaction: return "hand.tap"
        case .event: return "wave.3.right"
        case .diagnostic: return "stethoscope"
        case .error: return "exclamationmark.triangle"
        }
    }
}

private func settingsHeader(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title)
            .font(.title2.weight(.semibold))
        Text(detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
