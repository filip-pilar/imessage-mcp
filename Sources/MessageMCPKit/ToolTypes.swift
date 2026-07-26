import Foundation

public struct ToolDefinition: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: [String: AnySendable]
    public let annotations: [String: AnySendable]

    public init(
        name: String,
        title: String,
        description: String,
        inputSchema: [String: Any],
        readOnly: Bool,
        destructive: Bool = false,
        idempotent: Bool = false,
        openWorld: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema.mapValues(AnySendable.init)
        self.annotations = [
            "title": AnySendable(title),
            "readOnlyHint": AnySendable(readOnly),
            "destructiveHint": AnySendable(destructive),
            "idempotentHint": AnySendable(idempotent),
            "openWorldHint": AnySendable(openWorld),
        ]
    }

    public var jsonObject: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema.mapValues(\.value),
            "annotations": annotations.mapValues(\.value),
        ]
    }
}

/// Safely carries JSON-compatible values across Sendable boundaries.
public struct AnySendable: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
}

public struct ToolCallResult: Sendable {
    public let content: [AnySendable]
    public let structuredContent: AnySendable?
    public let isError: Bool

    public init(content: [[String: Any]], structuredContent: Any? = nil, isError: Bool = false) {
        self.content = content.map(AnySendable.init)
        self.structuredContent = structuredContent.map(AnySendable.init)
        self.isError = isError
    }

    public static func text(_ text: String, structured: Any? = nil) -> ToolCallResult {
        ToolCallResult(content: [["type": "text", "text": text]], structuredContent: structured)
    }

    public static func error(_ text: String) -> ToolCallResult {
        ToolCallResult(content: [["type": "text", "text": text]], isError: true)
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "content": content.map(\.value),
            "isError": isError,
        ]
        if let structuredContent {
            object["structuredContent"] = structuredContent.value
        }
        return object
    }
}

public enum ToolServiceError: LocalizedError {
    case invalid(String)
    case disabled(String)
    case denied

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .disabled(let message):
            return message
        case .denied:
            return "The action was not approved in the iMessage MCP menu."
        }
    }
}
