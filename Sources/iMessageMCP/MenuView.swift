import AppKit
import MessageMCPKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let request = model.approvals.first {
                    approvalCard(request)
                }

                section("Connection") { connectionSection }

                if shouldShowPermissionNote {
                    permissionNote
                }

                section("Write Access") { writeAccessSection }
                section("App") { appSection }

                if let entry = model.activities.first {
                    latestActivity(entry)
                }

                if let error = model.lastError {
                    errorCard(error)
                }

                footer
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .frame(width: 372, height: popoverHeight)
        .onAppear {
            model.refreshPermissionState()
        }
    }

    private var popoverHeight: CGFloat {
        let availableHeight = NSScreen.main?.visibleFrame.height ?? 760
        return min(680, max(480, availableHeight - 80))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text("iMessage MCP")
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(primaryStatus.color)
                        .frame(width: 6, height: 6)
                    Text(primaryStatus.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(primaryStatus.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(primaryStatus.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    primaryStatus.color.opacity(0.10),
                    in: Capsule()
                )
        }
    }

    private var connectionSection: some View {
        VStack(spacing: 0) {
            statusRow(
                icon: "externaldrive.fill",
                label: "Messages database",
                value: model.databaseAccess.label,
                color: model.databaseAccess.color,
                actionable: model.databaseAccess != .granted,
                action: { model.openFullDiskAccess() }
            )
            rowDivider
            statusRow(
                icon: "gearshape.2.fill",
                label: "Messages control",
                value: model.messagesAutomationAccess.label,
                color: model.messagesAutomationAccess.color,
                actionable: model.messagesAutomationAccess == .denied,
                action: { model.openAutomation() }
            )
            rowDivider
            statusRow(
                icon: "hand.tap.fill",
                label: "Tapback access",
                value: tapbackStatus.value,
                color: tapbackStatus.color,
                actionable: tapbackStatus.actionable,
                action: tapbackStatus.action
            )
            rowDivider
            clientStatusRow
            rowDivider
            statusToggleRow(
                icon: "wave.3.right",
                title: "Live updates",
                status: model.liveEventsRunning ? "Listening" : "Stopped",
                statusColor: model.liveEventsRunning ? .green : .secondary,
                isOn: Binding(
                    get: { model.settings.liveEventsEnabled },
                    set: { model.setLiveEvents($0) }
                )
            )
        }
    }

    private var writeAccessSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: policyIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 21)
                Text("Mode")
                    .font(.subheadline)
                Spacer(minLength: 8)
                Picker(
                    "Write access mode",
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
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Write access mode")
            }
            .frame(minHeight: 38)

            Text(model.writePolicyPreset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30)
                .padding(.bottom, 9)
        }
    }

    private var clientStatusRow: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(spacing: 9) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 21)
                Text("Active MCP sessions")
                    .font(.subheadline)
                Spacer()
                if model.clientCount == 1, let client = model.clients.first {
                    Text("\(client.name) connected")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(client.name)
                        .foregroundStyle(.green)
                } else if model.clientCount > 1 {
                    Text("\(model.clientCount) connected")
                        .foregroundStyle(.green)
                } else if let lastConnected = model.lastClientConnectedAt {
                    Text(lastActiveLabel(lastConnected))
                        .foregroundStyle(.secondary)
                        .help("Last active session")
                } else {
                    Text("Connects on demand")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(minHeight: 34)
        }
    }

    private func lastActiveLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last active \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var appSection: some View {
        settingRow(
            title: "Open at login",
            subtitle: "Keeps live updates available after restart",
            icon: "arrow.clockwise",
            isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            )
        )
    }

    private var permissionNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("macOS asks once for Messages control on the first send. Tapbacks can ask separately for System Events.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 3)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.activities.isEmpty {
                Button {
                    model.copyMCPCommand()
                } label: {
                    Label("Copy Setup Command", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
            } else {
                Button {
                    openSettingsWindow()
                } label: {
                    Label("View Activity…", systemImage: "clock")
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
            }
            Spacer()
            footerButton("gearshape", help: "Open Settings") {
                openSettingsWindow()
            }
            footerButton("power", help: "Quit iMessage MCP") {
                model.stop()
                NSApp.terminate(nil)
            }
        }
        .padding(.top, 1)
    }

    private func latestActivity(_ entry: ActivityEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(entry.succeeded ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                Text(entry.detail)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.timestamp, style: .relative)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 3)
        .help("\(entry.title): \(entry.detail)")
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }

    private var tapbackStatus: (
        value: String,
        color: Color,
        actionable: Bool,
        action: () -> Void
    ) {
        if !model.accessibilityAccess {
            return ("Grant Accessibility", .orange, true, model.openAccessibility)
        }
        switch model.systemEventsAutomationAccess {
        case .allowed:
            return ("Ready", .green, false, {})
        case .denied:
            return ("Needs System Events", .orange, true, model.openAutomation)
        case .notRequested:
            return ("Asked on first tapback", .secondary, false, {})
        case .unavailable:
            return ("Accessibility ready", .green, false, {})
        }
    }

    private var shouldShowPermissionNote: Bool {
        model.messagesAutomationAccess == .notRequested
            || model.messagesAutomationAccess == .unavailable
            || model.systemEventsAutomationAccess == .notRequested
    }

    private var primaryStatus: (title: String, subtitle: String, color: Color) {
        if !model.brokerRunning {
            return ("Stopped", "Broker unavailable", .orange)
        }
        if model.databaseAccess != .granted {
            return ("Needs Setup", "Messages access required", .orange)
        }
        if !model.settings.writesEnabled {
            return ("Read Only", "History and live updates ready", .blue)
        }
        return ("Ready", "Messages integration ready", .green)
    }

    private var policyIcon: String {
        switch model.writePolicyPreset {
        case .readOnly: return "lock.fill"
        case .confirmEveryWrite: return "checkmark.shield.fill"
        case .allowWithoutAsking: return "paperplane.fill"
        case .custom: return "slider.horizontal.3"
        }
    }

    private func openSettingsWindow() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 32)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
            content()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 11)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.055), lineWidth: 0.5)
                )
        }
    }

    private func approvalCard(_ request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: request.kind == .send ? "paperplane.fill" : "heart.fill")
                .font(.subheadline.weight(.semibold))
            Text(request.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
            HStack(alignment: .center) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(ceil(request.expiresAt.timeIntervalSince(context.date))))
                    Text("Expires in \(seconds)s")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel") { model.deny(request) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(request.kind == .send ? "Send Message" : "Add Tapback") {
                    model.approve(request)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusRow(
        icon: String,
        label: String,
        value: String,
        color: Color,
        actionable: Bool = false,
        action: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 21)
            Text(label)
                .font(.subheadline)
            Spacer()
            if actionable {
                Button(value, action: action)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.10), in: Capsule())
            } else {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(color)
            }
        }
        .frame(minHeight: 34)
    }

    private func statusToggleRow(
        icon: String,
        title: String,
        status: String,
        statusColor: Color,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 21)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(minHeight: 42)
    }

    private func settingRow(
        title: String,
        subtitle: String? = nil,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 21)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(minHeight: subtitle == nil ? 38 : 44)
    }

    private func footerButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
