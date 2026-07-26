import Foundation

public final class ToolService: @unchecked Sendable {
    public let runner: IMsgRunning
    public let settings: SettingsStore
    public let activity: ActivityStore
    public let events: EventStore
    public let approvals: ApprovalProviding
    let statusProvider: @Sendable () -> [String: Any]

    public init(
        runner: IMsgRunning,
        settings: SettingsStore,
        activity: ActivityStore,
        events: EventStore,
        approvals: ApprovalProviding,
        statusProvider: @escaping @Sendable () -> [String: Any] = { [:] }
    ) {
        self.runner = runner
        self.settings = settings
        self.activity = activity
        self.events = events
        self.approvals = approvals
        self.statusProvider = statusProvider
    }

    public func call(name: String, arguments: [String: Any]) -> ToolCallResult {
        do {
            switch name {
            case "check_setup": return try checkSetup()
            case "list_chats": return try listChats(arguments)
            case "get_chat": return try getChat(arguments)
            case "get_chat_background": return try getChatBackground(arguments)
            case "get_messages": return try getMessages(arguments)
            case "search_messages": return try searchMessages(arguments)
            case "message_statistics": return try statistics(arguments)
            case "list_scheduled_messages": return try scheduled(arguments)
            case "list_local_accounts": return try localAccounts()
            case "lookup_handle": return try lookupHandle(arguments)
            case "get_new_messages": return try newMessages(arguments)
            case "wait_for_message": return try waitForMessage(arguments)
            case "read_attachment": return try readAttachment(arguments)
            case "send_message": return try sendMessage(arguments)
            case "react_to_latest": return try react(arguments)
            case "get_send_status": return try sendStatus(arguments)
            default:
                return .error("Unknown tool: \(name)")
            }
        } catch {
            activity.append(
                ActivityEntry(
                    kind: .error,
                    title: name,
                    detail: error.localizedDescription,
                    succeeded: false
                )
            )
            return .error(error.localizedDescription)
        }
    }
}
