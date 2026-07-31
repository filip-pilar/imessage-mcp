import Foundation

public struct ConnectionInfo: Codable, Equatable, Sendable {
    public let socketPath: String
    public let token: String
    public let appPID: Int32
    public let version: String

    public init(socketPath: String, token: String, appPID: Int32, version: String) {
        self.socketPath = socketPath
        self.token = token
        self.appPID = appPID
        self.version = version
    }
}

public enum ConnectionInfoReadiness: Equatable, Sendable {
    case ready
    case staleProcess
    case incompatibleVersion
}

public enum RuntimeCompatibility {
    public static func connectionReadiness(
        _ info: ConnectionInfo,
        proxyVersion: String,
        processIsRunning: (Int32) -> Bool
    ) -> ConnectionInfoReadiness {
        guard processIsRunning(info.appPID) else { return .staleProcess }
        guard versionsAreCompatible(proxyVersion: proxyVersion, appVersion: info.version) else {
            return .incompatibleVersion
        }
        return .ready
    }

    public static func versionsAreCompatible(proxyVersion: String, appVersion: String) -> Bool {
        guard let proxyMajor = semanticMajor(proxyVersion),
              let appMajor = semanticMajor(appVersion) else {
            return false
        }
        return proxyMajor == appMajor
    }

    private static func semanticMajor(_ version: String) -> Int? {
        let core = version.prefix { $0 != "-" && $0 != "+" }
        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]) else {
            return nil
        }
        return major
    }
}

public struct MCPClientStatus: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let connectedAt: Date
    public let initialized: Bool

    public init(
        id: UUID,
        name: String,
        connectedAt: Date,
        initialized: Bool
    ) {
        self.id = id
        self.name = name
        self.connectedAt = connectedAt
        self.initialized = initialized
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var writesEnabled = true
    public var confirmSends = true
    public var confirmReactions = true
    public var approvalNotificationsEnabled = false
    public var liveEventsEnabled = true
    public var launchAtLogin = false
    public var maxAttachmentBytes = 100 * 1_024 * 1_024
    public var imsgOverridePath: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case writesEnabled
        case confirmSends
        case confirmReactions
        case approvalNotificationsEnabled
        case liveEventsEnabled
        case launchAtLogin
        case maxAttachmentBytes
        case imsgOverridePath
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        writesEnabled = try values.decodeIfPresent(Bool.self, forKey: .writesEnabled) ?? true
        confirmSends = try values.decodeIfPresent(Bool.self, forKey: .confirmSends) ?? true
        confirmReactions = try values.decodeIfPresent(Bool.self, forKey: .confirmReactions) ?? true
        approvalNotificationsEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .approvalNotificationsEnabled
        ) ?? false
        liveEventsEnabled = try values.decodeIfPresent(Bool.self, forKey: .liveEventsEnabled) ?? true
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        maxAttachmentBytes = try values.decodeIfPresent(
            Int.self,
            forKey: .maxAttachmentBytes
        ) ?? 100 * 1_024 * 1_024
        imsgOverridePath = try values.decodeIfPresent(String.self, forKey: .imsgOverridePath)
    }
}

public enum ActivityKind: String, Codable, Sendable {
    case read
    case send
    case reaction
    case event
    case diagnostic
    case error
}

public struct ActivityEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: ActivityKind
    public let title: String
    public let detail: String
    public let succeeded: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: ActivityKind,
        title: String,
        detail: String,
        succeeded: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.succeeded = succeeded
    }
}

public enum ApprovalKind: String, Codable, Sendable {
    case send
    case reaction
}

public struct ApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ApprovalKind
    public let title: String
    public let detail: String
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        kind: ApprovalKind,
        title: String,
        detail: String,
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct LiveEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: Int64
    public let receivedAt: Date
    public let payload: String

    public init(id: Int64, receivedAt: Date = Date(), payload: String) {
        self.id = id
        self.receivedAt = receivedAt
        self.payload = payload
    }
}

public struct LiveEventCursor: Equatable, Sendable {
    public let sessionID: UUID
    public let position: Int64

    public init(sessionID: UUID, position: Int64) {
        self.sessionID = sessionID
        self.position = position
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let sessionID = UUID(uuidString: String(parts[0])),
              let position = Int64(parts[1]),
              position >= 0 else {
            return nil
        }
        self.init(sessionID: sessionID, position: position)
    }

    public var rawValue: String {
        "\(sessionID.uuidString.lowercased()):\(position)"
    }
}

public struct LiveEventBatch: Equatable, Sendable {
    public let events: [LiveEvent]
    public let cursor: LiveEventCursor
    public let latestCursor: LiveEventCursor
    public let cursorExpired: Bool

    public init(
        events: [LiveEvent],
        cursor: LiveEventCursor,
        latestCursor: LiveEventCursor,
        cursorExpired: Bool
    ) {
        self.events = events
        self.cursor = cursor
        self.latestCursor = latestCursor
        self.cursorExpired = cursorExpired
    }
}

public enum LiveEventWaitResult: Equatable, Sendable {
    case events(LiveEventBatch)
    case timedOut(LiveEventCursor)
    case cursorExpired(LiveEventCursor)
}
