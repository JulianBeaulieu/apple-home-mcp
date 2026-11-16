import Foundation

/// Minimal Home Assistant WebSocket API client (https://developers.home-assistant.io/docs/api/websocket).
public final class HomeAssistantClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let timeout: TimeInterval

    public init(baseURL: URL, token: String, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.token = token
        self.timeout = timeout
    }

    public static func websocketURL(for base: URL) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http": comps.scheme = "ws"
        case "ws", "wss": break
        default: return nil
        }
        var path = comps.path
        if path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/api/websocket"
        comps.query = nil
        return comps.url
    }

    public final class Session: @unchecked Sendable {
        let task: URLSessionWebSocketTask
        var nextID = 1
        let timeout: TimeInterval
        init(task: URLSessionWebSocketTask, timeout: TimeInterval) {
            self.task = task
            self.timeout = timeout
        }

        func receiveJSON() async throws -> JSONValue {
            let message = try await withTimeout(timeout) { try await self.task.receive() }
            switch message {
            case .string(let s): return try JSONValue.parse(Data(s.utf8))
            case .data(let d): return try JSONValue.parse(d)
            @unknown default: throw ToolError("unexpected websocket frame")
            }
        }

        func send(_ value: JSONValue) async throws {
            try await task.send(.string(value.serializedString()))
        }

        /// Sends one command and waits for its result message.
        public func call(_ type: String, _ fields: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> JSONValue {
            let id = nextID
            nextID += 1
            var msg = fields
            msg["id"] = .number(Double(id))
            msg["type"] = .string(type)
            try await send(.object(msg))
            let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
            while Date() < deadline {
                let reply = try await receiveJSON()
                guard reply["id"]?.intValue == id else { continue }
                if reply["type"]?.stringValue == "result" {
                    if reply["success"]?.boolValue == true { return reply["result"] ?? .null }
                    let code = reply["error"]?["code"]?.stringValue ?? "error"
                    let message = reply["error"]?["message"]?.stringValue ?? "unknown error"
                    throw ToolError("Home Assistant \(type) failed: \(code): \(message)")
                }
            }
            throw ToolError("Home Assistant \(type) timed out")
        }
    }

    /// Opens a connection, authenticates, runs `body`, closes.
    public func withSession<T>(_ body: (Session) async throws -> T) async throws -> T {
        guard let wsURL = HomeAssistantClient.websocketURL(for: baseURL) else { throw ToolError("invalid Home Assistant URL") }
        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let session = Session(task: task, timeout: timeout)
        let hello = try await session.receiveJSON()
        guard hello["type"]?.stringValue == "auth_required" else { throw ToolError("unexpected Home Assistant greeting") }
        try await session.send(["type": "auth", "access_token": .string(token)])
        let auth = try await session.receiveJSON()
        guard auth["type"]?.stringValue == "auth_ok" else {
            throw ToolError("Home Assistant rejected the access token (\(auth["type"]?.stringValue ?? "?"))")
        }
        return try await body(session)
    }
}

func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ToolError("timed out after \(Int(seconds))s")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

// MARK: - Floors / areas sync planning

/// Apple Home has no floors. We model floors as HomeKit zones (optionally only zones with a
/// name prefix) and mirror them to Home Assistant floors; rooms become HA areas.
public enum AreaSync {
    public struct AppleRoom: Sendable, Equatable {
        public var name: String
        public var floor: String?
        public init(name: String, floor: String?) {
            self.name = name
            self.floor = floor
        }
    }

    public struct HAFloor: Sendable, Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct HAArea: Sendable, Equatable {
        public var id: String
        public var name: String
        public var floorID: String?
        public init(id: String, name: String, floorID: String?) { self.id = id; self.name = name; self.floorID = floorID }
    }

    public enum Action: Sendable, Equatable {
        case createFloor(name: String)
        case createArea(name: String, floor: String?)
        case setAreaFloor(areaID: String, areaName: String, floor: String)

        public var json: JSONValue {
            switch self {
            case .createFloor(let n): return ["action": "create_floor", "name": .string(n)]
            case .createArea(let n, let f): return ["action": "create_area", "name": .string(n), "floor": f.map { .string($0) } ?? .null]
            case .setAreaFloor(let id, let n, let f): return ["action": "set_area_floor", "area_id": .string(id), "area": .string(n), "floor": .string(f)]
            }
        }
    }

    static func key(_ s: String) -> String { SafetyPolicy.normalize(s) }

    /// Additive plan: never deletes or renames anything in Home Assistant, and never moves an
    /// area that already has a floor unless `reassignFloors` is set.
    public static func plan(floors: [String], rooms: [AppleRoom], haFloors: [HAFloor], haAreas: [HAArea], reassignFloors: Bool = false) -> [Action] {
        var actions: [Action] = []
        var floorIDByKey: [String: String] = [:]
        for f in haFloors { floorIDByKey[key(f.name)] = f.id }
        var seenFloors = Set<String>()
        for f in floors where !seenFloors.contains(key(f)) {
            seenFloors.insert(key(f))
            if floorIDByKey[key(f)] == nil { actions.append(.createFloor(name: f)) }
        }
        var areaByKey: [String: HAArea] = [:]
        for a in haAreas { areaByKey[key(a.name)] = a }
        var seenRooms = Set<String>()
        for r in rooms where !seenRooms.contains(key(r.name)) {
            seenRooms.insert(key(r.name))
            guard let area = areaByKey[key(r.name)] else {
                actions.append(.createArea(name: r.name, floor: r.floor))
                continue
            }
            guard let floor = r.floor else { continue }
            let wanted = floorIDByKey[key(floor)]
            if area.floorID == nil || (reassignFloors && area.floorID != wanted) {
                if area.floorID != wanted || wanted == nil {
                    actions.append(.setAreaFloor(areaID: area.id, areaName: area.name, floor: floor))
                }
            }
        }
        return actions
    }
}
