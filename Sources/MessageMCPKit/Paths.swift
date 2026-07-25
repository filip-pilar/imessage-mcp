import Foundation
import Darwin

public enum AppPaths {
    public static let appName = "iMessage MCP"

    public static var applicationSupport: URL {
        if let override = ProcessInfo.processInfo.environment["IMESSAGE_MCP_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static var connectionFile: URL {
        applicationSupport.appendingPathComponent("connection.json")
    }

    public static var settingsFile: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }

    public static var activityFile: URL {
        applicationSupport.appendingPathComponent("activity.json")
    }

    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["IMESSAGE_MCP_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return "/tmp/com.openai.imessage-mcp.\(getuid()).sock"
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
