import Foundation
import Testing
@testable import MessageMCPKit

@Suite("MCP protocol")
struct MCPProcessorTests {
    func processor() throws -> MCPProcessor {
        let env = try TestEnvironment()
        return MCPProcessor(
            tools: env.service(runner: FakeRunner()),
            statusProvider: { ["ready": true] }
        )
    }

    @Test("negotiates lifecycle and advertises capabilities")
    func initialize() throws {
        let processor = try processor()
        let session = MCPConnectionSession()
        let response = try decodeJSON(processor.process(
            line: mcpRequest(method: "initialize", params: [
                "protocolVersion": "2025-11-25",
                "clientInfo": ["name": "tests", "version": "1"],
                "capabilities": [:],
            ]),
            session: session
        ))
        let result = response["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-11-25")
        #expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(session.initialized)
        #expect(session.clientName == "tests")
    }

    @Test("lists tools and resources")
    func listsCapabilities() throws {
        let processor = try processor()
        let session = MCPConnectionSession()
        let toolsResponse = try decodeJSON(processor.process(
            line: mcpRequest(method: "tools/list"),
            session: session
        ))
        let tools = (toolsResponse["result"] as? [String: Any])?["tools"] as? [Any]
        #expect(tools?.count == ToolService.tools.count)

        let resourcesResponse = try decodeJSON(processor.process(
            line: mcpRequest(method: "resources/list"),
            session: session
        ))
        let resources = (resourcesResponse["result"] as? [String: Any])?["resources"] as? [Any]
        #expect(resources?.count == 2)
    }

    @Test("returns JSON-RPC errors for unknown methods")
    func unknownMethod() throws {
        let response = try decodeJSON(try processor().process(
            line: mcpRequest(method: "unknown/method"),
            session: MCPConnectionSession()
        ))
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32601)
    }

    @Test("resource subscriptions receive standard notification shape")
    func subscription() throws {
        let session = MCPConnectionSession()
        _ = try processor().process(
            line: mcpRequest(method: "resources/subscribe", params: ["uri": MCPProcessor.eventsURI]),
            session: session
        )
        #expect(session.isSubscribed(to: MCPProcessor.eventsURI))
        let notification = try decodeJSON(MCPProcessor.resourceUpdatedNotification(uri: MCPProcessor.eventsURI))
        #expect(notification["method"] as? String == "notifications/resources/updated")
    }
}
