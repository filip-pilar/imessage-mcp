import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissionState()
    }
}

@main
struct MessageMCPMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(delegate.model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: delegate.model.approvals.isEmpty
                    ? "message.fill"
                    : "exclamationmark.message.fill")
                if !delegate.model.approvals.isEmpty {
                    Text(delegate.model.approvals.count > 9
                        ? "9+"
                        : "\(delegate.model.approvals.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .accessibilityLabel(delegate.model.approvals.isEmpty
                ? "iMessage MCP"
                : "\(delegate.model.approvals.count) pending approvals")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(delegate.model)
        }
    }
}
