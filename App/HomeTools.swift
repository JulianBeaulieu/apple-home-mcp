import Foundation
import HomeKit
import MCPKit

/// All MCP tools. Every handler hops to the main actor (HomeKit is main-thread bound).
@MainActor
final class HomeTools {
    let store: HomeStore
    let matter: MatterBridge
    let config: ConfigStore
    let activity: (String) -> Void

    init(store: HomeStore, matter: MatterBridge, config: ConfigStore, activity: @escaping (String) -> Void) {
        self.store = store
        self.matter = matter
        self.config = config
        self.activity = activity
    }

    var policy: SafetyPolicy { config.config.safetyPolicy }
    var cfg: AppConfig { config.config }

    // MARK: Argument helpers

    static func str(_ a: JSONValue, _ key: String) throws -> String {
        guard let s = a[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            throw ToolError("missing required argument '\(key)'")
        }
        return s
    }

    static func optStr(_ a: JSONValue, _ key: String) -> String? {
        guard let s = a[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func requireConfirm(_ a: JSONValue, _ what: String) throws {
        guard a["confirm"]?.boolValue == true else {
            throw ToolError("\(what) needs \"confirm\": true. Ask the human first, then call again with confirm=true.")
        }
    }

    func home(_ a: JSONValue) async throws -> HMHome {
        try await store.home(HomeTools.optStr(a, "home"), defaultHome: cfg.defaultHome)
    }

    func check(_ acc: HMAccessory, _ kind: WriteKind) throws {
        if case .deny(let why) = policy.evaluate(Protected.facts(acc), kind) {
            activity("refused \(kind.rawValue) on a protected accessory")
            throw ToolError("refused: \(why)")
        }
    }

    static let homeArg: JSONValue = Schema.string("Home name or id. Defaults to the configured/primary home.")
    static let confirmArg: JSONValue = Schema.boolean("Must be true. Only set after the human approved this exact action.")

    func tool(_ name: String, _ title: String, _ description: String, _ props: [String: JSONValue], required: [String] = [],
              _ annotations: ToolAnnotations, _ body: @escaping @MainActor (JSONValue) async throws -> JSONValue) -> Tool {
        var p = props
        p["home"] = HomeTools.homeArg
        return Tool(name: name, title: title, description: description, inputSchema: Schema.object(p, required: required),
                    annotations: annotations) { args in
            try await body(args)
        }
    }

    // MARK: Registry

    func all() -> [Tool] {
        readTools() + organizeTools() + floorTools() + pairingTools() + homeAssistantTools() + controlTools()
    }

    // MARK: Read

    func readTools() -> [Tool] {
        [
            tool("list_homes", "List homes", "List the Apple Home homes this Mac can see, with counts.", [:], .read) { [unowned self] _ in
                try await store.waitUntilLoaded()
                return ["homes": .array(store.manager.homes.map { Serialize.home($0) }),
                        "authorization": .string(store.authorizationDescription)]
            },
            tool("get_home", "Home overview",
                 "Rooms (with zone/floor), zones, scenes and accessory summaries for one home. Start here.", [:], .read) { [unowned self] a in
                let h = try await home(a)
                let prefix = cfg.floorZonePrefix
                return [
                    "home": Serialize.home(h),
                    "rooms": .array(([h.roomForEntireHome()] + h.rooms).map { Serialize.room($0, home: h, floorPrefix: prefix) }),
                    "zones": .array(h.zones.map { Serialize.zone($0, floorPrefix: prefix) }),
                    "scenes": .array(h.actionSets.map { Serialize.scene($0) }),
                    "accessories": .array(h.accessories.map { Serialize.accessorySummary($0, policy: policy) }),
                ]
            },
            tool("list_rooms", "List rooms", "Rooms with their zones, floor and accessory count.", [:], .read) { [unowned self] a in
                let h = try await home(a)
                return ["rooms": .array(([h.roomForEntireHome()] + h.rooms).map { Serialize.room($0, home: h, floorPrefix: cfg.floorZonePrefix) })]
            },
            tool("list_zones", "List zones", "Zones and the rooms in each. Zones double as floors (see list_floors).", [:], .read) { [unowned self] a in
                let h = try await home(a)
                return ["zones": .array(h.zones.map { Serialize.zone($0, floorPrefix: cfg.floorZonePrefix) })]
            },
            tool("list_accessories", "List accessories",
                 "Accessory summaries, optionally filtered by room or text. Shows matter_node_id for Matter accessories, and protected/denylisted flags.",
                 ["room": Schema.string("Only accessories in this room (name or id)."),
                  "query": Schema.string("Case-insensitive substring of name, manufacturer, model or category."),
                  "matter_only": Schema.boolean("Only Matter accessories.")], .read) { [unowned self] a in
                let h = try await home(a)
                var list = h.accessories
                if let r = HomeTools.optStr(a, "room") {
                    let room = try store.room(r, in: h)
                    list = list.filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
                }
                if let q = HomeTools.optStr(a, "query").map(SafetyPolicy.normalize) {
                    list = list.filter { acc in
                        [acc.name, acc.manufacturer ?? "", acc.model ?? "", acc.category.localizedDescription]
                            .contains { SafetyPolicy.normalize($0).contains(q) }
                    }
                }
                if a["matter_only"]?.boolValue == true { list = list.filter { Serialize.matterNodeHex($0) != nil } }
                return ["count": .number(Double(list.count)), "accessories": .array(list.map { Serialize.accessorySummary($0, policy: policy) })]
            },
            tool("get_accessory", "Accessory details",
                 "Services and characteristics (with metadata and values) of one accessory. refresh=true reads live values from the device.",
                 ["accessory": Schema.string("Accessory name or id."),
                  "refresh": Schema.boolean("Read current values from the device first (slower).")],
                 required: ["accessory"], .read) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                var errors: [JSONValue] = []
                if a["refresh"]?.boolValue == true {
                    for s in acc.services {
                        for c in s.characteristics where c.properties.contains(HMCharacteristicPropertyReadable) {
                            do { try await c.readValue() } catch { errors.append(.string("\(c.localizedDescription): \(error.localizedDescription)")) }
                        }
                    }
                }
                var detail = Serialize.accessoryDetail(acc, policy: policy)
                if !errors.isEmpty, case .object(var o) = detail { o["read_errors"] = .array(errors); detail = .object(o) }
                return detail
            },
            tool("list_scenes", "List scenes", "Scenes (action sets) in the home.", [:], .read) { [unowned self] a in
                let h = try await home(a)
                return ["scenes": .array(h.actionSets.map { Serialize.scene($0) })]
            },
            tool("get_policy", "Safety policy",
                 "What this server will refuse: protected kinds, denylist size, whether control writes are enabled.", [:], .read) { [unowned self] a in
                let h = try await home(a)
                let denied = h.accessories.filter { policy.denylistMatch(Protected.facts($0)) != nil }
                let protected = h.accessories.filter { !Protected.kinds($0).isEmpty }
                return [
                    "control_enabled": .bool(cfg.controlEnabled),
                    "protected_kinds": .array(policy.protectedKinds.sorted().map { .string($0) }),
                    "denylist_entries": .number(Double(cfg.denylist.count)),
                    "denylisted_accessories": .array(denied.map { .string($0.name) }),
                    "protected_accessories": .array(protected.map { .string($0.name) }),
                    "rules": [
                        "denylisted: every write refused (control, rename/move, sharing)",
                        "locks, garage doors, security systems: control writes always refused",
                        "other accessories: control writes only when control_enabled",
                    ],
                ]
            },
        ]
    }

    // MARK: Organize

    func organizeTools() -> [Tool] {
        [
            tool("rename_accessory", "Rename accessory", "Rename an accessory in Apple Home.",
                 ["accessory": Schema.string("Accessory name or id."), "name": Schema.string("New name.")],
                 required: ["accessory", "name"], .write) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                try check(acc, .organize)
                let old = acc.name
                try await acc.updateName(HomeTools.str(a, "name"))
                activity("renamed accessory")
                return ["ok": true, "id": .string(acc.uniqueIdentifier.uuidString), "old_name": .string(old), "name": .string(acc.name)]
            },
            tool("move_accessory", "Move accessory to room", "Assign an accessory to a room.",
                 ["accessory": Schema.string("Accessory name or id."), "room": Schema.string("Target room name or id.")],
                 required: ["accessory", "room"], .write) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                try check(acc, .organize)
                let room = try store.room(HomeTools.str(a, "room"), in: h)
                let old = acc.room?.name
                try await h.assignAccessory(acc, to: room)
                activity("moved accessory")
                return ["ok": true, "accessory": .string(acc.name), "from": old.map { .string($0) } ?? .null, "to": .string(room.name)]
            },
            tool("create_room", "Create room", "Create a room. Optionally put it on a floor (zone).",
                 ["name": Schema.string("Room name."), "floor": Schema.string("Optional floor name (zone) to add the room to; created if missing.")],
                 required: ["name"], .write) { [unowned self] a in
                let h = try await home(a)
                let name = try HomeTools.str(a, "name")
                if h.rooms.contains(where: { SafetyPolicy.normalize($0.name) == SafetyPolicy.normalize(name) }) {
                    throw ToolError("a room named '\(name)' already exists")
                }
                let room = try await h.addRoom(named: name)
                activity("created room")
                var out: [String: JSONValue] = ["ok": true, "room": Serialize.room(room, home: h, floorPrefix: cfg.floorZonePrefix)]
                if let floor = HomeTools.optStr(a, "floor") {
                    out["floor"] = try await setFloor(room: room, floor: floor, home: h, create: true)
                }
                return .object(out)
            },
            tool("rename_room", "Rename room", "Rename a room.",
                 ["room": Schema.string("Room name or id."), "name": Schema.string("New name.")],
                 required: ["room", "name"], .write) { [unowned self] a in
                let h = try await home(a)
                let room = try store.room(HomeTools.str(a, "room"), in: h)
                let old = room.name
                try await room.updateName(HomeTools.str(a, "name"))
                activity("renamed room")
                return ["ok": true, "old_name": .string(old), "name": .string(room.name)]
            },
            tool("delete_room", "Delete room",
                 "Delete a room. Its accessories fall back to the default room. Refuses rooms that contain denylisted accessories.",
                 ["room": Schema.string("Room name or id."), "confirm": HomeTools.confirmArg],
                 required: ["room", "confirm"], .destructiveWrite) { [unowned self] a in
                let h = try await home(a)
                let room = try store.room(HomeTools.str(a, "room"), in: h)
                guard room.uniqueIdentifier != h.roomForEntireHome().uniqueIdentifier else { throw ToolError("the default room cannot be deleted") }
                for acc in room.accessories { try check(acc, .organize) }
                try HomeTools.requireConfirm(a, "Deleting room '\(room.name)' (\(room.accessories.count) accessories)")
                let name = room.name, moved = room.accessories.map { JSONValue.string($0.name) }
                try await h.removeRoom(room)
                activity("deleted room")
                return ["ok": true, "deleted": .string(name), "accessories_moved_to_default_room": .array(moved)]
            },
            tool("create_zone", "Create zone", "Create a zone (a group of rooms).",
                 ["name": Schema.string("Zone name.")], required: ["name"], .write) { [unowned self] a in
                let h = try await home(a)
                let z = try await h.addZone(named: HomeTools.str(a, "name"))
                activity("created zone")
                return ["ok": true, "zone": Serialize.zone(z, floorPrefix: cfg.floorZonePrefix)]
            },
            tool("rename_zone", "Rename zone", "Rename a zone.",
                 ["zone": Schema.string("Zone name or id."), "name": Schema.string("New name.")],
                 required: ["zone", "name"], .write) { [unowned self] a in
                let h = try await home(a)
                let z = try store.zone(HomeTools.str(a, "zone"), in: h)
                let old = z.name
                try await z.updateName(HomeTools.str(a, "name"))
                activity("renamed zone")
                return ["ok": true, "old_name": .string(old), "name": .string(z.name)]
            },
            tool("delete_zone", "Delete zone", "Delete a zone. Rooms are kept.",
                 ["zone": Schema.string("Zone name or id."), "confirm": HomeTools.confirmArg],
                 required: ["zone", "confirm"], .destructiveWrite) { [unowned self] a in
                let h = try await home(a)
                let z = try store.zone(HomeTools.str(a, "zone"), in: h)
                try HomeTools.requireConfirm(a, "Deleting zone '\(z.name)'")
                let name = z.name
                try await h.removeZone(z)
                activity("deleted zone")
                return ["ok": true, "deleted": .string(name)]
            },
            tool("add_room_to_zone", "Add room to zone", "Add a room to a zone (rooms can be in several zones).",
                 ["room": Schema.string("Room name or id."), "zone": Schema.string("Zone name or id.")],
                 required: ["room", "zone"], .write) { [unowned self] a in
                let h = try await home(a)
                let room = try store.room(HomeTools.str(a, "room"), in: h)
                let z = try store.zone(HomeTools.str(a, "zone"), in: h)
                if !z.rooms.contains(where: { $0.uniqueIdentifier == room.uniqueIdentifier }) { try await z.addRoom(room) }
                activity("added room to zone")
                return ["ok": true, "zone": Serialize.zone(z, floorPrefix: cfg.floorZonePrefix)]
            },
            tool("remove_room_from_zone", "Remove room from zone", "Remove a room from a zone.",
                 ["room": Schema.string("Room name or id."), "zone": Schema.string("Zone name or id.")],
                 required: ["room", "zone"], .write) { [unowned self] a in
                let h = try await home(a)
                let room = try store.room(HomeTools.str(a, "room"), in: h)
                let z = try store.zone(HomeTools.str(a, "zone"), in: h)
                if z.rooms.contains(where: { $0.uniqueIdentifier == room.uniqueIdentifier }) { try await z.removeRoom(room) }
                activity("removed room from zone")
                return ["ok": true, "zone": Serialize.zone(z, floorPrefix: cfg.floorZonePrefix)]
            },
        ]
    }

    // MARK: Floors (= zones)

    func floorZones(_ h: HMHome) -> [HMZone] { h.zones.filter { Floors.isFloor($0, prefix: cfg.floorZonePrefix) } }

    func setFloor(room: HMRoom, floor: String, home h: HMHome, create: Bool) async throws -> JSONValue {
        let prefix = cfg.floorZonePrefix
        let wanted = SafetyPolicy.normalize(floor)
        var target = floorZones(h).first { SafetyPolicy.normalize(Floors.floorName($0, prefix: prefix)) == wanted }
        if target == nil {
            guard create else { throw ToolError("floor '\(floor)' does not exist; pass create=true or call create_floor") }
            target = try await h.addZone(named: Floors.zoneName(forFloor: floor, prefix: prefix))
        }
        let t = target!
        // A room sits on exactly one floor: leave other floor-zones (non-floor zones untouched).
        for z in floorZones(h) where z.uniqueIdentifier != t.uniqueIdentifier && z.rooms.contains(where: { $0.uniqueIdentifier == room.uniqueIdentifier }) {
            try await z.removeRoom(room)
        }
        if !t.rooms.contains(where: { $0.uniqueIdentifier == room.uniqueIdentifier }) { try await t.addRoom(room) }
        return .string(Floors.floorName(t, prefix: prefix))
    }

    func floorTools() -> [Tool] {
        [
            tool("list_floors", "List floors",
                 "Floors and their rooms. Apple Home has no floors; this server models each floor as a zone (only zones starting with floor_zone_prefix when that is set).",
                 [:], .read) { [unowned self] a in
                let h = try await home(a)
                let prefix = cfg.floorZonePrefix
                let floors = floorZones(h)
                let onFloor = Set(floors.flatMap { $0.rooms.map { $0.uniqueIdentifier } })
                return [
                    "floor_zone_prefix": .string(prefix),
                    "floors": .array(floors.map { ["name": .string(Floors.floorName($0, prefix: prefix)), "zone": .string($0.name),
                                                   "zone_id": .string($0.uniqueIdentifier.uuidString),
                                                   "rooms": .array($0.rooms.map { .string($0.name) })] }),
                    "rooms_without_floor": .array(h.rooms.filter { !onFloor.contains($0.uniqueIdentifier) }.map { .string($0.name) }),
                ]
            },
            tool("create_floor", "Create floor", "Create a floor (a zone named floor_zone_prefix + name).",
                 ["name": Schema.string("Floor name, e.g. 'Upstairs'.")], required: ["name"], .write) { [unowned self] a in
                let h = try await home(a)
                let name = try HomeTools.str(a, "name")
                if floorZones(h).contains(where: { SafetyPolicy.normalize(Floors.floorName($0, prefix: cfg.floorZonePrefix)) == SafetyPolicy.normalize(name) }) {
                    throw ToolError("floor '\(name)' already exists")
                }
                let z = try await h.addZone(named: Floors.zoneName(forFloor: name, prefix: cfg.floorZonePrefix))
                activity("created floor")
                return ["ok": true, "floor": .string(name), "zone": .string(z.name)]
            },
            tool("rename_floor", "Rename floor", "Rename a floor (renames its zone, keeping the prefix).",
                 ["floor": Schema.string("Current floor name."), "name": Schema.string("New floor name.")],
                 required: ["floor", "name"], .write) { [unowned self] a in
                let h = try await home(a)
                let prefix = cfg.floorZonePrefix
                let cur = SafetyPolicy.normalize(try HomeTools.str(a, "floor"))
                guard let z = floorZones(h).first(where: { SafetyPolicy.normalize(Floors.floorName($0, prefix: prefix)) == cur }) else {
                    throw ToolError("floor not found")
                }
                try await z.updateName(Floors.zoneName(forFloor: HomeTools.str(a, "name"), prefix: prefix))
                activity("renamed floor")
                return ["ok": true, "zone": .string(z.name)]
            },
            tool("set_room_floor", "Put room on floor",
                 "Put a room on a floor: adds it to that floor's zone and removes it from other floor zones (non-floor zones are untouched).",
                 ["room": Schema.string("Room name or id."), "floor": Schema.string("Floor name."),
                  "create": Schema.boolean("Create the floor if it does not exist.")],
                 required: ["room", "floor"], .write) { [unowned self] a in
                let h = try await home(a)
                let room = try store.room(HomeTools.str(a, "room"), in: h)
                let f = try await setFloor(room: room, floor: HomeTools.str(a, "floor"), home: h, create: a["create"]?.boolValue == true)
                activity("set room floor")
                return ["ok": true, "room": .string(room.name), "floor": f]
            },
        ]
    }

    // MARK: Pairing

    func pairingTools() -> [Tool] {
        [
            tool("add_accessory", "Add a new accessory (guided)",
                 """
                 Start adding a new accessory to Apple Home. macOS cannot run HomeKit accessory setup (HMAccessorySetupManager is \
                 unavailable on macOS/Mac Catalyst), so this returns the steps for the human to do on an iPhone/iPad and decodes the \
                 Matter code if given (vendor/product/discriminator; the passcode is never echoed). Then call wait_for_new_accessory, \
                 and afterwards rename_accessory / move_accessory / matter_share_to_home_assistant.
                 """,
                 ["setup_code": Schema.string("Optional Matter QR payload (MT:...) or manual pairing code, to sanity-check it."),
                  "suggested_name": Schema.string("Name the human should give it."),
                  "suggested_room": Schema.string("Room the human should pick.")], .read) { [unowned self] a in
                let h = try await home(a)
                var steps: [JSONValue] = [
                    .string("On an iPhone or iPad signed into the same Apple ID, open the Home app and select the home '\(h.name)'."),
                    "Tap + › Add Accessory and scan the Matter QR code (or tap 'More options…' and enter the setup code).",
                    "For Thread/Matter devices, keep the phone near the device; the Apple home hub/border router will commission it onto Thread.",
                ]
                if let n = HomeTools.optStr(a, "suggested_name") { steps.append(.string("Name it '\(n)'.")) }
                if let r = HomeTools.optStr(a, "suggested_room") { steps.append(.string("Choose the room '\(r)' (or let the agent move it afterwards).")) }
                steps.append("Tell the agent when it is done; it can then call wait_for_new_accessory.")
                var out: [String: JSONValue] = [
                    "can_add_from_mac": false,
                    "reason": "HMAccessorySetupManager and HMAccessorySetupPayload are marked API_UNAVAILABLE(macos, macCatalyst) in the HomeKit SDK.",
                    "human_steps": .array(steps),
                    "started_at": .string(ISO8601DateFormatter().string(from: Date())),
                ]
                if let code = HomeTools.optStr(a, "setup_code") {
                    out["setup_code_info"] = MatterBridge.describePayload(code) ?? ["error": "not a valid Matter setup payload"]
                }
                return .object(out)
            },
            tool("wait_for_new_accessory", "Wait for a new accessory",
                 "Wait until an accessory is added to the home (via the Home app) and return it. Returns null on timeout.",
                 ["timeout_seconds": Schema.integer("How long to wait (default 120, max 600).", minimum: 1, maximum: 600),
                  "since": Schema.string("ISO-8601 time; accessories added after it count (default: now). Use add_accessory's started_at.")],
                 .read) { [unowned self] a in
                let h = try await home(a)
                let timeout = Double(min(max(a["timeout_seconds"]?.intValue ?? 120, 1), 600))
                let since = HomeTools.optStr(a, "since").flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                guard let acc = await store.waitForNewAccessory(home: h, since: since, timeout: timeout) else {
                    return ["accessory": .null, "timed_out": true]
                }
                return ["accessory": Serialize.accessoryDetail(acc, policy: policy), "timed_out": false]
            },
            tool("matter_info", "Matter info (read-only)",
                 "Read Matter Basic Information and how many fabrics (controllers) an Apple-Home Matter accessory has, over HomeKit's Matter XPC controller. Read-only.",
                 ["accessory": Schema.string("Accessory name or id.")], required: ["accessory"], .read) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                return try await matter.basicInfo(home: h, accessory: acc)
            },
            tool("matter_open_pairing_window", "Open Matter pairing window",
                 """
                 Open a Matter multi-admin commissioning window on an Apple-Home Matter accessory and return a fresh one-time \
                 pairing code, so another controller can add it (same as 'Turn On Pairing Mode' in the Home app). Needs confirm=true. \
                 If Apple Home refuses, the result says so and gives the manual fallback.
                 """,
                 ["accessory": Schema.string("Accessory name or id."),
                  "seconds": Schema.integer("Window length, 180-900 (default 600).", minimum: 180, maximum: 900),
                  "confirm": HomeTools.confirmArg], required: ["accessory", "confirm"], .write) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                try check(acc, .share)
                try HomeTools.requireConfirm(a, "Opening a pairing window on '\(acc.name)'")
                do {
                    let w = try await matter.openCommissioningWindow(home: h, accessory: acc, seconds: a["seconds"]?.intValue ?? 600)
                    activity("opened Matter pairing window")
                    return ["ok": true, "accessory": .string(acc.name), "manual_pairing_code": .string(w.manualCode),
                            "qr_payload": w.qrCode.map { .string($0) } ?? .null,
                            "expires_at": .string(ISO8601DateFormatter().string(from: w.expires)), "method": .string(w.method)]
                } catch let e as ToolError {
                    throw ToolError(e.message, details: ["attempts": e.details ?? .null, "fallback": HomeTools.manualPairingFallback(acc.name)])
                }
            },
            tool("matter_close_pairing_window", "Close Matter pairing window",
                 "Close an open commissioning window early (AdministratorCommissioning.RevokeCommissioning). Existing controllers are unaffected.",
                 ["accessory": Schema.string("Accessory name or id.")], required: ["accessory"], .write) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                try check(acc, .share)
                try await matter.closeCommissioningWindow(home: h, accessory: acc)
                activity("closed Matter pairing window")
                return ["ok": true, "accessory": .string(acc.name)]
            },
            tool("matter_share_to_home_assistant", "Share Matter accessory with Home Assistant",
                 """
                 Primary onboarding flow: give a Matter accessory that is already in Apple Home to Home Assistant's Matter \
                 integration (multi-admin; Apple Home keeps it). Opens a pairing window via Apple Home (or uses pairing_code if the \
                 human turned on pairing mode in the Home app), then calls Home Assistant's matter/commission. Needs confirm=true.
                 """,
                 ["accessory": Schema.string("Accessory name or id."),
                  "pairing_code": Schema.string("Optional code from Home app › accessory › Turn On Pairing Mode. Skips opening a window."),
                  "confirm": HomeTools.confirmArg], required: ["accessory", "confirm"], .write) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                try check(acc, .share)
                _ = try matter.nodeID(acc)
                try HomeTools.requireConfirm(a, "Sharing '\(acc.name)' with Home Assistant")
                let ha = try homeAssistant()
                var code = HomeTools.optStr(a, "pairing_code")?.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
                var method = "pairing_code_from_human"
                if code == nil {
                    do {
                        let w = try await matter.openCommissioningWindow(home: h, accessory: acc, seconds: 600)
                        code = w.manualCode
                        method = w.method
                    } catch let e as ToolError {
                        throw ToolError("could not open a pairing window via Apple Home: \(e.message)",
                                        details: ["attempts": e.details ?? .null, "fallback": HomeTools.manualPairingFallback(acc.name)])
                    }
                }
                let result = try await ha.withSession { s in
                    try await s.call("matter/commission", ["code": .string(code!), "network_only": true], timeout: 300)
                }
                activity("shared Matter accessory with Home Assistant")
                return ["ok": true, "accessory": .string(acc.name), "window_method": .string(method), "home_assistant_result": result,
                        "next": "In Home Assistant the device appears under Settings › Devices › Matter. Assign its area (or run ha_sync_areas)."]
            },
        ]
    }

    static func manualPairingFallback(_ name: String) -> JSONValue {
        [
            "human_steps": [
                .string("In the Home app (iPhone, iPad or Mac), open '\(name)' › settings (gear) › scroll down › Turn On Pairing Mode."),
                "Copy the 11-digit setup code that appears (valid ~15 minutes).",
                "Give the code to the agent; it calls matter_share_to_home_assistant with pairing_code=<code> (or ha_commission_matter).",
            ],
        ]
    }

    // MARK: Home Assistant

    func homeAssistant() throws -> HomeAssistantClient {
        let urlString = cfg.homeAssistant.url
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            throw ToolError("Home Assistant is not configured. Menu bar › Home Assistant… (URL + long-lived token).")
        }
        guard let token = Keychain.read(Keychain.homeAssistantTokenAccount), !token.isEmpty else {
            throw ToolError("no Home Assistant token in the Keychain. Menu bar › Home Assistant…")
        }
        return HomeAssistantClient(baseURL: url, token: token)
    }

    func homeAssistantTools() -> [Tool] {
        [
            tool("ha_status", "Home Assistant status",
                 "Check the Home Assistant connection, version and whether the Matter integration is loaded. Read-only.", [:], .read) { [unowned self] _ in
                let ha = try homeAssistant()
                return try await ha.withSession { s in
                    let config = try await s.call("get_config")
                    let entries = try await s.call("config_entries/get", ["domain": "matter"])
                    let matter = (entries.arrayValue ?? []).map { e -> JSONValue in ["title": e["title"] ?? .null, "state": e["state"] ?? .null] }
                    return ["connected": true, "version": config["version"] ?? .null,
                            "matter_integration": .array(matter)]
                }
            },
            tool("ha_commission_matter", "Commission Matter code in Home Assistant",
                 "Commission a Matter device into Home Assistant with a pairing code (e.g. from Turn On Pairing Mode). Needs confirm=true.",
                 ["code": Schema.string("11/21-digit manual code or MT: QR payload."),
                  "network_only": Schema.boolean("Device is already on the network/Thread (multi-admin). Default true."),
                  "confirm": HomeTools.confirmArg], required: ["code", "confirm"], .write) { [unowned self] a in
                try HomeTools.requireConfirm(a, "Commissioning a Matter device in Home Assistant")
                let ha = try homeAssistant()
                let code = try HomeTools.str(a, "code").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
                let r = try await ha.withSession { s in
                    try await s.call("matter/commission", ["code": .string(code), "network_only": .bool(a["network_only"]?.boolValue ?? true)], timeout: 300)
                }
                activity("commissioned Matter device in Home Assistant")
                return ["ok": true, "result": r]
            },
            tool("ha_sync_areas", "Mirror rooms/floors to Home Assistant",
                 """
                 Mirror Apple Home floors (zones) and rooms into Home Assistant floors and areas. Additive only: never deletes or \
                 renames in Home Assistant. dry_run (default true) returns the plan; apply needs dry_run=false and confirm=true.
                 """,
                 ["dry_run": Schema.boolean("Only return the plan (default true)."),
                  "reassign_floors": Schema.boolean("Also move HA areas that already have a different floor."),
                  "confirm": HomeTools.confirmArg], .write) { [unowned self] a in
                let h = try await home(a)
                let prefix = cfg.floorZonePrefix
                let floors = floorZones(h)
                let rooms = h.rooms.map { r in
                    AreaSync.AppleRoom(name: r.name, floor: floors.first { $0.rooms.contains { $0.uniqueIdentifier == r.uniqueIdentifier } }
                        .map { Floors.floorName($0, prefix: prefix) })
                }
                let floorNames = floors.map { Floors.floorName($0, prefix: prefix) }
                let dryRun = a["dry_run"]?.boolValue ?? true
                if !dryRun { try HomeTools.requireConfirm(a, "Writing floors/areas to Home Assistant") }
                let ha = try homeAssistant()
                let reassign = a["reassign_floors"]?.boolValue == true
                return try await ha.withSession { s in
                    let haFloors = try await s.call("config/floor_registry/list").arrayValue ?? []
                    let haAreas = try await s.call("config/area_registry/list").arrayValue ?? []
                    let plan = AreaSync.plan(
                        floors: floorNames, rooms: rooms,
                        haFloors: haFloors.compactMap { f in f["floor_id"]?.stringValue.map { AreaSync.HAFloor(id: $0, name: f["name"]?.stringValue ?? "") } },
                        haAreas: haAreas.compactMap { x in x["area_id"]?.stringValue.map { AreaSync.HAArea(id: $0, name: x["name"]?.stringValue ?? "", floorID: x["floor_id"]?.stringValue) } },
                        reassignFloors: reassign)
                    if dryRun { return ["dry_run": true, "plan": .array(plan.map { $0.json })] }
                    var floorIDs: [String: String] = [:]
                    for f in haFloors { if let id = f["floor_id"]?.stringValue, let n = f["name"]?.stringValue { floorIDs[SafetyPolicy.normalize(n)] = id } }
                    var done: [JSONValue] = []
                    for step in plan {
                        switch step {
                        case .createFloor(let name):
                            let r = try await s.call("config/floor_registry/create", ["name": .string(name)])
                            if let id = r["floor_id"]?.stringValue { floorIDs[SafetyPolicy.normalize(name)] = id }
                        case .createArea(let name, let floor):
                            var fields: [String: JSONValue] = ["name": .string(name)]
                            if let floor, let id = floorIDs[SafetyPolicy.normalize(floor)] { fields["floor_id"] = .string(id) }
                            _ = try await s.call("config/area_registry/create", fields)
                        case .setAreaFloor(let areaID, _, let floor):
                            guard let id = floorIDs[SafetyPolicy.normalize(floor)] else { continue }
                            _ = try await s.call("config/area_registry/update", ["area_id": .string(areaID), "floor_id": .string(id)])
                        }
                        done.append(step.json)
                    }
                    self.activity("synced areas to Home Assistant")
                    return ["dry_run": false, "applied": .array(done)]
                }
            },
        ]
    }

    // MARK: Control (gated)

    func controlTools() -> [Tool] {
        [
            tool("set_characteristic", "Set characteristic (gated)",
                 """
                 Write a characteristic value (e.g. power, brightness). Disabled unless control_enabled is set locally. Always \
                 refused for locks, garage doors, security systems and denylisted accessories.
                 """,
                 ["accessory": Schema.string("Accessory name or id."),
                  "characteristic": Schema.string("Characteristic id, type UUID, or its type name as shown by get_accessory (e.g. 'Power State', 'Brightness')."),
                  "service": Schema.string("Optional service name/id/type to disambiguate."),
                  "value": Schema.any("New value (bool, number or string as the characteristic expects).")],
                 required: ["accessory", "characteristic", "value"], .write) { [unowned self] a in
                let h = try await home(a)
                let acc = try store.accessory(HomeTools.str(a, "accessory"), in: h)
                try check(acc, .control)
                let c = try characteristic(acc, HomeTools.str(a, "characteristic"), service: HomeTools.optStr(a, "service"))
                guard !Protected.characteristicTypes.contains(c.characteristicType) else {
                    throw ToolError("refused: \(c.localizedDescription) is a security-relevant characteristic")
                }
                guard c.properties.contains(HMCharacteristicPropertyWritable) else { throw ToolError("\(c.localizedDescription) is not writable") }
                let v = try HomeTools.coerce(a["value"] ?? .null, for: c)
                try await c.writeValue(v)
                activity("wrote characteristic")
                return ["ok": true, "accessory": .string(acc.name), "characteristic": .string(c.localizedDescription), "value": Serialize.value(c.value, format: c.metadata?.format)]
            },
            tool("run_scene", "Run scene (gated)",
                 "Execute a scene. Disabled unless control_enabled; refused if the scene touches any protected or denylisted accessory.",
                 ["scene": Schema.string("Scene name or id.")], required: ["scene"], .write) { [unowned self] a in
                let h = try await home(a)
                let scene = try store.scene(HomeTools.str(a, "scene"), in: h)
                guard cfg.controlEnabled else { throw ToolError("refused: control writes are disabled (control_enabled=false)") }
                for action in scene.actions {
                    guard let w = action as? HMCharacteristicWriteAction<NSCopying> else {
                        throw ToolError("refused: scene '\(scene.name)' contains an action type this server cannot vet")
                    }
                    if let acc = w.characteristic.service?.accessory { try check(acc, .control) }
                    if Protected.characteristicTypes.contains(w.characteristic.characteristicType) {
                        throw ToolError("refused: scene '\(scene.name)' changes a security-relevant characteristic")
                    }
                }
                try await h.executeActionSet(scene)
                activity("ran scene")
                return ["ok": true, "scene": .string(scene.name)]
            },
        ]
    }

    func characteristic(_ acc: HMAccessory, _ ref: String, service: String?) throws -> HMCharacteristic {
        var services = acc.services
        if let service {
            let key = SafetyPolicy.normalize(service)
            services = services.filter {
                $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(service) == .orderedSame || $0.serviceType.caseInsensitiveCompare(service) == .orderedSame
                    || SafetyPolicy.normalize($0.name) == key || SafetyPolicy.normalize($0.localizedDescription) == key
            }
        }
        let key = SafetyPolicy.normalize(ref)
        let hits = services.flatMap { $0.characteristics }.filter {
            $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(ref) == .orderedSame || $0.characteristicType.caseInsensitiveCompare(ref) == .orderedSame
                || SafetyPolicy.normalize($0.localizedDescription) == key
        }
        guard hits.count == 1 else {
            throw ToolError(hits.isEmpty ? "characteristic '\(ref)' not found" : "characteristic '\(ref)' is ambiguous; pass service or the characteristic id",
                            details: .array(hits.map { .string("\($0.service?.name ?? "?") / \($0.localizedDescription) (\($0.uniqueIdentifier.uuidString))") }))
        }
        return hits[0]
    }

    static func coerce(_ v: JSONValue, for c: HMCharacteristic) throws -> Any {
        let format = c.metadata?.format ?? ""
        switch format {
        case HMCharacteristicMetadataFormatBool:
            guard let b = v.boolValue else { throw ToolError("expected a boolean") }
            return b
        case HMCharacteristicMetadataFormatString:
            guard let s = v.stringValue else { throw ToolError("expected a string") }
            return s
        case HMCharacteristicMetadataFormatInt, HMCharacteristicMetadataFormatUInt8, HMCharacteristicMetadataFormatUInt16,
             HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64, HMCharacteristicMetadataFormatFloat:
            guard let d = v.doubleValue else { throw ToolError("expected a number") }
            if let m = c.metadata?.minimumValue?.doubleValue, d < m { throw ToolError("value below minimum \(m)") }
            if let m = c.metadata?.maximumValue?.doubleValue, d > m { throw ToolError("value above maximum \(m)") }
            if let valid = c.metadata?.validValues, !valid.isEmpty, !valid.contains(where: { $0.doubleValue == d }) {
                throw ToolError("value not in valid_values \(valid.map { $0.intValue })")
            }
            return format == HMCharacteristicMetadataFormatFloat ? NSNumber(value: d) : NSNumber(value: Int(d))
        default:
            throw ToolError("writing \(format.isEmpty ? "this" : format) characteristics is not supported")
        }
    }
}
