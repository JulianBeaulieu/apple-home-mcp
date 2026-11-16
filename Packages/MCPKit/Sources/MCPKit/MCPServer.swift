import Foundation

/// Error thrown by tool handlers; surfaced to the client as an MCP tool result with `isError: true`.
public struct ToolError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let details: JSONValue?
    public init(_ message: String, details: JSONValue? = nil) {
        self.message = message
        self.details = details
    }
    public var description: String { message }
}

public struct ToolAnnotations: Sendable {
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool
    public var openWorld: Bool
    public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool = false, openWorld: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }
    public static let read = ToolAnnotations(readOnly: true, idempotent: true)
    public static let write = ToolAnnotations(readOnly: false)
    public static let destructiveWrite = ToolAnnotations(readOnly: false, destructive: true)

    var json: JSONValue {
        ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
         "idempotentHint": .bool(idempotent), "openWorldHint": .bool(openWorld)]
    }
}

public struct Tool: Sendable {
    public typealias Handler = @Sendable (JSONValue) async throws -> JSONValue
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: ToolAnnotations
    public let handler: Handler

    public init(name: String, title: String, description: String, inputSchema: JSONValue, annotations: ToolAnnotations, handler: @escaping Handler) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.handler = handler
    }

    var listing: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "inputSchema": inputSchema, "annotations": annotations.json]
    }
}

/// Helpers to build JSON Schemas tersely.
public enum Schema {
    public static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }
    public static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }
    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { o["minimum"] = .number(Double(minimum)) }
        if let maximum { o["maximum"] = .number(Double(maximum)) }
        return .object(o)
    }
    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }
    public static func any(_ description: String) -> JSONValue {
        ["description": .string(description)]
    }
    public static func stringArray(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
}

/// MCP (Model Context Protocol) server core: JSON-RPC dispatch + streamable-HTTP framing.
///
/// Transport notes (MCP 2025-06-18 "Streamable HTTP"): every client message is a POST to the
/// endpoint. Requests get a single `application/json` response (which the spec permits instead
/// of an SSE stream); notifications and responses get `202 Accepted`. We do not offer a
/// server-initiated GET stream, so GET returns 405 as the spec allows.
public final class MCPServer: @unchecked Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let serverName: String
    public let serverVersion: String
    public let instructions: String
    private let lock = NSLock()
    private var toolsByName: [String: Tool] = [:]
    private var toolOrder: [String] = []
    private var sessions: Set<String> = []
    public var accessPolicy: @Sendable () -> AccessPolicy
    public var onToolCall: (@Sendable (String, Bool) -> Void)?

    public init(name: String, version: String, instructions: String, accessPolicy: @escaping @Sendable () -> AccessPolicy) {
        self.serverName = name
        self.serverVersion = version
        self.instructions = instructions
        self.accessPolicy = accessPolicy
    }

    public func register(_ tools: [Tool]) {
        lock.lock(); defer { lock.unlock() }
        for t in tools {
            if toolsByName[t.name] == nil { toolOrder.append(t.name) }
            toolsByName[t.name] = t
        }
    }

    public var tools: [Tool] {
        lock.lock(); defer { lock.unlock() }
        return toolOrder.compactMap { toolsByName[$0] }
    }

    // MARK: HTTP

    public func handleHTTP(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET" && request.path == "/health" {
            return .json(["status": "ok", "server": .string(serverName), "version": .string(serverVersion)])
        }
        guard request.path == "/mcp" || request.path == "/mcp/" else {
            return .text("not found\n", status: 404)
        }
        if case .deny(let status, let reason) = accessPolicy().evaluate(request) {
            var headers: [(String, String)] = []
            if status == 401 { headers.append(("WWW-Authenticate", "Bearer realm=\"apple-home-mcp\"")) }
            return .json(["error": .string(reason)], status: status, extraHeaders: headers)
        }
        switch request.method {
        case "POST": break
        case "DELETE":
            if let sid = request.header("mcp-session-id") {
                _ = lock.withLock { sessions.remove(sid) }
            }
            return HTTPResponse(status: 204)
        default:
            return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")])
        }
        if let ct = request.header("content-type"), !ct.lowercased().contains("application/json") {
            return .text("expected application/json\n", status: 415)
        }
        let message: JSONValue
        do {
            message = try JSONValue.parse(request.body)
        } catch {
            return .json(MCPServer.errorResponse(id: .null, code: -32700, message: "parse error"), status: 400)
        }

        if case .array(let batch) = message {
            var out: [JSONValue] = []
            var newSession: String?
            for m in batch {
                let (resp, sid) = await handleMessage(m)
                if let resp { out.append(resp) }
                if let sid { newSession = sid }
            }
            if out.isEmpty { return HTTPResponse(status: 202) }
            return .json(.array(out), extraHeaders: newSession.map { [("Mcp-Session-Id", $0)] } ?? [])
        }
        let (response, sid) = await handleMessage(message)
        guard let response else { return HTTPResponse(status: 202) }
        return .json(response, extraHeaders: sid.map { [("Mcp-Session-Id", $0)] } ?? [])
    }

    // MARK: JSON-RPC

    /// Returns (response or nil for notifications, newly created session id).
    public func handleMessage(_ message: JSONValue) async -> (JSONValue?, String?) {
        guard case .object(let obj) = message else {
            return (MCPServer.errorResponse(id: .null, code: -32600, message: "invalid request"), nil)
        }
        let id = obj["id"]
        guard let method = obj["method"]?.stringValue else {
            // A response from the client (we never send requests) or garbage. Accept silently.
            return (id == nil ? nil : nil, nil)
        }
        let params = obj["params"] ?? .object([:])
        let isNotification = id == nil
        if isNotification {
            return (nil, nil)  // notifications/initialized, notifications/cancelled, ...
        }
        let rid = id!
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? MCPServer.supportedProtocolVersions[0]
            let version = MCPServer.supportedProtocolVersions.contains(requested) ? requested : MCPServer.supportedProtocolVersions[0]
            let sid = UUID().uuidString
            _ = lock.withLock { sessions.insert(sid) }
            let result: JSONValue = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(serverName), "version": .string(serverVersion)],
                "instructions": .string(instructions),
            ]
            return (MCPServer.result(id: rid, result), sid)
        case "ping":
            return (MCPServer.result(id: rid, .object([:])), nil)
        case "tools/list":
            return (MCPServer.result(id: rid, ["tools": .array(tools.map { $0.listing })]), nil)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return (MCPServer.errorResponse(id: rid, code: -32602, message: "missing tool name"), nil)
            }
            let tool: Tool? = lock.withLock { toolsByName[name] }
            guard let tool else {
                return (MCPServer.errorResponse(id: rid, code: -32602, message: "unknown tool: \(name)"), nil)
            }
            let args = params["arguments"] ?? .object([:])
            do {
                let value = try await tool.handler(args)
                onToolCall?(name, true)
                return (MCPServer.result(id: rid, MCPServer.toolResult(value, isError: false)), nil)
            } catch let e as ToolError {
                onToolCall?(name, false)
                var payload: [String: JSONValue] = ["error": .string(e.message)]
                if let d = e.details { payload["details"] = d }
                return (MCPServer.result(id: rid, MCPServer.toolResult(.object(payload), isError: true)), nil)
            } catch {
                onToolCall?(name, false)
                return (MCPServer.result(id: rid, MCPServer.toolResult(["error": .string(error.localizedDescription)], isError: true)), nil)
            }
        case "resources/list":
            return (MCPServer.result(id: rid, ["resources": []]), nil)
        case "prompts/list":
            return (MCPServer.result(id: rid, ["prompts": []]), nil)
        default:
            return (MCPServer.errorResponse(id: rid, code: -32601, message: "method not found: \(method)"), nil)
        }
    }

    static func toolResult(_ value: JSONValue, isError: Bool) -> JSONValue {
        var r: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(value.serializedString(pretty: true))]],
            "isError": .bool(isError),
        ]
        if case .object = value { r["structuredContent"] = value }
        return .object(r)
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
