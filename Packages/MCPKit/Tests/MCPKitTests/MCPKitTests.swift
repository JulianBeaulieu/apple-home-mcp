import XCTest
@testable import MCPKit

final class HTTPParserTests: XCTestCase {
    func testParsesRequestWithBodyAcrossChunks() throws {
        var p = HTTPRequestParser()
        p.append(Data("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8737\r\nContent-Type: application/json\r\nContent-Len".utf8))
        XCTAssertNil(try p.next())
        p.append(Data("gth: 4\r\n\r\n{}".utf8))
        XCTAssertNil(try p.next())
        p.append(Data("\n\nGET /health HTTP/1.1\r\n\r\n".utf8))
        let r = try XCTUnwrap(try p.next())
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(r.query, "x=1")
        XCTAssertEqual(r.header("HOST"), "127.0.0.1:8737")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{}\n\n")
        let r2 = try XCTUnwrap(try p.next())
        XCTAssertEqual(r2.path, "/health")
    }

    func testRejectsOversizedBodyAndChunked() {
        var p = HTTPRequestParser(maxBodyBytes: 10)
        p.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8))
        XCTAssertThrowsError(try p.next()) { XCTAssertEqual($0 as? HTTPRequestParser.ParseError, .bodyTooLarge) }
        var q = HTTPRequestParser()
        q.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        XCTAssertThrowsError(try q.next())
        var m = HTTPRequestParser()
        m.append(Data("garbage\r\n\r\n".utf8))
        XCTAssertThrowsError(try m.next())
    }
}

final class AuthTests: XCTestCase {
    func req(host: String = "127.0.0.1:8737", origin: String? = nil, auth: String? = nil) -> HTTPRequest {
        var h = ["Host": host]
        if let origin { h["Origin"] = origin }
        if let auth { h["Authorization"] = auth }
        return HTTPRequest(method: "POST", path: "/mcp", headers: h)
    }

    func testGeneratedKeysAreUniqueAndLong() {
        let a = APIKey.generate(), b = APIKey.generate()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("ahmcp_"))
        XCTAssertGreaterThanOrEqual(a.count, 40)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(APIKey.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(APIKey.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(APIKey.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(APIKey.constantTimeEquals("", "a"))
    }

    func testBearerParsing() {
        XCTAssertEqual(APIKey.bearerToken(from: "Bearer xyz"), "xyz")
        XCTAssertEqual(APIKey.bearerToken(from: "bearer   xyz "), "xyz")
        XCTAssertNil(APIKey.bearerToken(from: "Basic xyz"))
        XCTAssertNil(APIKey.bearerToken(from: "Bearer"))
    }

    func testLoopbackWithoutKeyRequirement() {
        let p = AccessPolicy(networkExposed: false, requireKeyOnLoopback: false, apiKey: nil)
        XCTAssertEqual(p.evaluate(req()), .allow)
        XCTAssertEqual(p.evaluate(req(host: "localhost:8737")), .allow)
        XCTAssertEqual(p.evaluate(req(host: "[::1]:8737")), .allow)
        // DNS rebinding: evil.example resolving to 127.0.0.1
        if case .allow = p.evaluate(req(host: "evil.example:8737")) { XCTFail("foreign host must be rejected") }
        if case .allow = p.evaluate(req(origin: "https://evil.example")) { XCTFail("foreign origin must be rejected") }
        if case .allow = p.evaluate(req(origin: "null")) { XCTFail("null origin must be rejected") }
        XCTAssertEqual(p.evaluate(req(origin: "http://localhost:3000")), .allow)
    }

    func testKeyRequiredOnLoopback() {
        let p = AccessPolicy(networkExposed: false, requireKeyOnLoopback: true, apiKey: "secret")
        XCTAssertEqual(p.evaluate(req(auth: "Bearer secret")), .allow)
        if case .allow = p.evaluate(req()) { XCTFail() }
        if case .allow = p.evaluate(req(auth: "Bearer wrong")) { XCTFail() }
    }

    func testNetworkModeAlwaysRequiresKey() {
        let p = AccessPolicy(networkExposed: true, requireKeyOnLoopback: false, apiKey: "secret")
        if case .allow = p.evaluate(req(host: "studio.local:8737")) { XCTFail("network mode must need a key") }
        XCTAssertEqual(p.evaluate(req(host: "studio.local:8737", auth: "Bearer secret")), .allow)
        let noKey = AccessPolicy(networkExposed: true, requireKeyOnLoopback: false, apiKey: nil)
        if case .allow = noKey.evaluate(req(auth: "Bearer ")) { XCTFail("network mode without configured key must refuse") }
    }
}

final class PolicyTests: XCTestCase {
    let policy = SafetyPolicy(denylist: ["Gartentuer", "*garage*", "Kitchen/Aquarium Pump", "Network Cabinet plug", "0F0E-UUID"], controlEnabled: true)

    func facts(_ name: String, room: String? = "Office", kinds: Set<String> = [], id: String = "X") -> AccessoryFacts {
        AccessoryFacts(id: id, name: name, room: room, protectedKinds: kinds)
    }

    func testDenylistMatchesUmlautsCaseGlobRoomAndUUID() {
        XCTAssertNotNil(policy.denylistMatch(facts("Gartentür")))
        XCTAssertNotNil(policy.denylistMatch(facts("GARTENTUER")))
        XCTAssertNotNil(policy.denylistMatch(facts("Big Garage Door")))
        XCTAssertNotNil(policy.denylistMatch(facts("Aquarium pump", room: "Kitchen")))
        XCTAssertNil(policy.denylistMatch(facts("Aquarium pump", room: "Basement")))
        XCTAssertNotNil(policy.denylistMatch(facts("network  cabinet Plug")))
        XCTAssertNotNil(policy.denylistMatch(facts("anything", id: "0f0e-uuid")))
        XCTAssertNil(policy.denylistMatch(facts("Desk Lamp")))
    }

    func testDenylistedRefusesEverything() {
        for kind in [WriteKind.control, .organize, .share] {
            XCTAssertFalse(policy.evaluate(facts("Gartentuer"), kind).isAllowed, "\(kind)")
        }
    }

    func testProtectedKindsRefuseControlOnly() {
        let lock = facts("New Lock", kinds: ["lock"])
        XCTAssertFalse(policy.evaluate(lock, .control).isAllowed)
        XCTAssertTrue(policy.evaluate(lock, .organize).isAllowed)
        XCTAssertTrue(policy.evaluate(lock, .share).isAllowed)
        XCTAssertFalse(policy.evaluate(facts("Opener", kinds: ["garage_door"]), .control).isAllowed)
        XCTAssertFalse(policy.evaluate(facts("Alarm", kinds: ["security_system"]), .control).isAllowed)
    }

    func testControlNeedsOptIn() {
        let off = SafetyPolicy(denylist: [], controlEnabled: false)
        XCTAssertFalse(off.evaluate(facts("Lamp"), .control).isAllowed)
        XCTAssertTrue(off.evaluate(facts("Lamp"), .organize).isAllowed)
        XCTAssertTrue(policy.evaluate(facts("Lamp"), .control).isAllowed)
    }

    func testConfigCannotShrinkProtectedKinds() throws {
        let json = #"{"protected_kinds": [], "control_enabled": true}"#
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertFalse(c.safetyPolicy.evaluate(facts("L", kinds: ["lock"]), .control).isAllowed)
    }

    func testConfigDefaultsAreSafe() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(c.exposeOnNetwork)
        XCTAssertFalse(c.controlEnabled)
        XCTAssertTrue(c.requireAPIKeyOnLoopback)
        XCTAssertEqual(c.port, 8737)
    }

    func testConfigStoreRoundTripAndInvalidFileKeepsPrevious() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: file)
        try store.update { $0.denylist = ["A"] }
        XCTAssertEqual(ConfigStore(fileURL: file).config.denylist, ["A"])
        try Data("{not json".utf8).write(to: file)
        XCTAssertNotNil(store.reload())
        XCTAssertEqual(store.config.denylist, ["A"])
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        try? FileManager.default.removeItem(at: dir)
    }
}

final class MCPServerTests: XCTestCase {
    func makeServer(policy: AccessPolicy = AccessPolicy(networkExposed: false, requireKeyOnLoopback: false, apiKey: nil)) -> MCPServer {
        let s = MCPServer(name: "test", version: "0", instructions: "hi", accessPolicy: { policy })
        s.register([
            Tool(name: "echo", title: "Echo", description: "", inputSchema: Schema.object([:]), annotations: .read) { args in
                ["got": args]
            },
            Tool(name: "boom", title: "Boom", description: "", inputSchema: Schema.object([:]), annotations: .write) { _ in
                throw ToolError("nope")
            },
        ])
        return s
    }

    func post(_ s: MCPServer, _ body: String, headers: [String: String] = [:]) async -> HTTPResponse {
        var h = ["Host": "127.0.0.1:8737", "Content-Type": "application/json"]
        h.merge(headers) { _, b in b }
        return await s.handleHTTP(HTTPRequest(method: "POST", path: "/mcp", headers: h, body: Data(body.utf8)))
    }

    func testInitializeListCall() async throws {
        let s = makeServer()
        let r = await post(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.headers.contains { $0.0 == "Mcp-Session-Id" })
        let init_ = try JSONValue.parse(r.body)
        XCTAssertEqual(init_["result"]?["protocolVersion"], "2025-06-18")

        let n = await post(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(n.status, 202)

        let l = try JSONValue.parse(await post(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#).body)
        XCTAssertEqual(l["result"]?["tools"]?.arrayValue?.count, 2)

        let c = try JSONValue.parse(await post(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"a":1}}}"#).body)
        XCTAssertEqual(c["result"]?["isError"], false)
        XCTAssertEqual(c["result"]?["structuredContent"]?["got"]?["a"], 1)

        let e = try JSONValue.parse(await post(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"boom"}}"#).body)
        XCTAssertEqual(e["result"]?["isError"], true)
        XCTAssertEqual(e["result"]?["structuredContent"]?["error"], "nope")

        let u = try JSONValue.parse(await post(s, #"{"jsonrpc":"2.0","id":5,"method":"nope"}"#).body)
        XCTAssertEqual(u["error"]?["code"], -32601)
    }

    func testUnknownProtocolVersionFallsBack() async throws {
        let r = try JSONValue.parse(await post(makeServer(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#).body)
        XCTAssertEqual(r["result"]?["protocolVersion"]?.stringValue, MCPServer.supportedProtocolVersions[0])
    }

    func testAuthEnforcedAndGetRejected() async throws {
        let s = makeServer(policy: AccessPolicy(networkExposed: true, requireKeyOnLoopback: true, apiKey: "k"))
        let denied = await post(s, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(denied.status, 401)
        let ok = await post(s, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, headers: ["Authorization": "Bearer k"])
        XCTAssertEqual(ok.status, 200)
        let get = await s.handleHTTP(HTTPRequest(method: "GET", path: "/mcp", headers: ["Host": "127.0.0.1", "Authorization": "Bearer k"]))
        XCTAssertEqual(get.status, 405)
        let bad = await post(s, "{oops", headers: ["Authorization": "Bearer k"])
        XCTAssertEqual(bad.status, 400)
    }
}

final class AreaSyncTests: XCTestCase {
    func testPlanIsAdditive() {
        let plan = AreaSync.plan(
            floors: ["Ground Floor", "Upstairs"],
            rooms: [.init(name: "Kitchen", floor: "Ground Floor"), .init(name: "Bedroom", floor: "Upstairs"),
                    .init(name: "Office", floor: "Upstairs"), .init(name: "Garden", floor: nil)],
            haFloors: [.init(id: "ground", name: "ground floor")],
            haAreas: [.init(id: "kitchen", name: "Kitchen", floorID: "ground"),
                      .init(id: "office", name: "Office", floorID: nil)])
        XCTAssertEqual(plan, [
            .createFloor(name: "Upstairs"),
            .createArea(name: "Bedroom", floor: "Upstairs"),
            .setAreaFloor(areaID: "office", areaName: "Office", floor: "Upstairs"),
            .createArea(name: "Garden", floor: nil),
        ])
    }

    func testExistingFloorAssignmentKeptUnlessReassign() {
        let rooms = [AreaSync.AppleRoom(name: "Kitchen", floor: "Upstairs")]
        let haFloors = [AreaSync.HAFloor(id: "g", name: "Ground"), .init(id: "u", name: "Upstairs")]
        let haAreas = [AreaSync.HAArea(id: "kitchen", name: "Kitchen", floorID: "g")]
        XCTAssertEqual(AreaSync.plan(floors: ["Upstairs"], rooms: rooms, haFloors: haFloors, haAreas: haAreas), [])
        XCTAssertEqual(AreaSync.plan(floors: ["Upstairs"], rooms: rooms, haFloors: haFloors, haAreas: haAreas, reassignFloors: true),
                       [.setAreaFloor(areaID: "kitchen", areaName: "Kitchen", floor: "Upstairs")])
    }

    func testCurlyApostropheMatchesStraight() {
        let plan = AreaSync.plan(floors: [], rooms: [.init(name: "Kid\u{2019}s Room", floor: nil)], haFloors: [],
                                 haAreas: [.init(id: "kids_room", name: "Kid's Room", floorID: nil)])
        XCTAssertEqual(plan, [])
    }

    func testWebsocketURL() {
        XCTAssertEqual(HomeAssistantClient.websocketURL(for: URL(string: "https://ha.example:8123/")!)?.absoluteString, "wss://ha.example:8123/api/websocket")
        XCTAssertEqual(HomeAssistantClient.websocketURL(for: URL(string: "http://ha.example")!)?.absoluteString, "ws://ha.example/api/websocket")
        XCTAssertNil(HomeAssistantClient.websocketURL(for: URL(string: "ftp://x")!))
    }
}

final class HTTPServerIntegrationTests: XCTestCase {
    func testServesOverLoopback() async throws {
        let port = UInt16.random(in: 40000...50000)
        let server = HTTPServer(port: port, bind: .loopback) { req in
            .json(["path": .string(req.path)])
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONValue.parse(data)["path"], "/health")
    }
}
