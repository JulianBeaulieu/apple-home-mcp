import Foundation
import HomeKit
import MCPKit

/// HomeKit object -> JSON. Kept close to what an agent needs; ids are HomeKit UUIDs.
@MainActor
enum Serialize {
    static func home(_ h: HMHome) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(h.uniqueIdentifier.uuidString),
            "name": .string(h.name),
            "rooms": .number(Double(h.rooms.count)),
            "zones": .number(Double(h.zones.count)),
            "accessories": .number(Double(h.accessories.count)),
            "scenes": .number(Double(h.actionSets.count)),
        ]
        o["primary"] = .bool(h.isPrimary)
        if #available(macCatalyst 16.1, *) {
            o["matter_controller_available"] = .bool(!h.matterControllerID.isEmpty)
        }
        return .object(o)
    }

    static func room(_ r: HMRoom, home: HMHome, floorPrefix: String) -> JSONValue {
        let zones = home.zones.filter { z in z.rooms.contains { $0.uniqueIdentifier == r.uniqueIdentifier } }
        let floor = zones.first { Floors.isFloor($0, prefix: floorPrefix) }.map { Floors.floorName($0, prefix: floorPrefix) }
        return [
            "id": .string(r.uniqueIdentifier.uuidString),
            "name": .string(r.name),
            "is_default_room": .bool(r.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier),
            "zones": .array(zones.map { .string($0.name) }),
            "floor": floor.map { .string($0) } ?? .null,
            "accessories": .number(Double(r.accessories.count)),
        ]
    }

    static func zone(_ z: HMZone, floorPrefix: String) -> JSONValue {
        [
            "id": .string(z.uniqueIdentifier.uuidString),
            "name": .string(z.name),
            "is_floor": .bool(Floors.isFloor(z, prefix: floorPrefix)),
            "rooms": .array(z.rooms.map { .string($0.name) }),
        ]
    }

    static func matterNodeHex(_ a: HMAccessory) -> String? {
        guard #available(macCatalyst 16.1, *), let n = a.matterNodeID, n != 0 else { return nil }  // 0 = HAP/bridged
        return String(format: "%016llX", n)
    }

    static func accessorySummary(_ a: HMAccessory, policy: SafetyPolicy) -> JSONValue {
        let facts = Protected.facts(a)
        var o: [String: JSONValue] = [
            "id": .string(a.uniqueIdentifier.uuidString),
            "name": .string(a.name),
            "room": a.room.map { .string($0.name) } ?? .null,
            "category": .string(a.category.localizedDescription),
            "reachable": .bool(a.isReachable),
            "bridged": .bool(a.isBridged),
            "services": .array(a.services.filter { $0.isUserInteractive }.map { .string($0.localizedDescription) }),
        ]
        if let m = a.manufacturer { o["manufacturer"] = .string(m) }
        if let m = a.model { o["model"] = .string(m) }
        if let hex = matterNodeHex(a) { o["matter_node_id"] = .string(hex) }
        if !facts.protectedKinds.isEmpty { o["protected"] = .array(facts.protectedKinds.sorted().map { .string($0) }) }
        if policy.denylistMatch(facts) != nil { o["denylisted"] = true }
        return .object(o)
    }

    static func accessoryDetail(_ a: HMAccessory, policy: SafetyPolicy) -> JSONValue {
        guard case .object(var o) = accessorySummary(a, policy: policy) else { return .null }
        if let fw = a.firmwareVersion { o["firmware"] = .string(fw) }
        o["blocked"] = a.isBlocked ? true : nil
        o["identify_supported"] = .bool(a.supportsIdentify)
        if let b = a.uniqueIdentifiersForBridgedAccessories, !b.isEmpty {
            o["bridged_accessory_ids"] = .array(b.map { .string($0.uuidString) })
        }
        o["services"] = .array(a.services.map { service($0) })
        return .object(o.filter { $0.value != .null })
    }

    static func service(_ s: HMService) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(s.uniqueIdentifier.uuidString),
            "name": .string(s.name),
            "type": .string(s.localizedDescription),
            "type_uuid": .string(s.serviceType),
            "primary": .bool(s.isPrimaryService),
            "characteristics": .array(s.characteristics.map { characteristic($0) }),
        ]
        if !s.isUserInteractive { o["user_interactive"] = false }
        return .object(o)
    }

    static func characteristic(_ c: HMCharacteristic) -> JSONValue {
        let props = Set(c.properties)
        var o: [String: JSONValue] = [
            "id": .string(c.uniqueIdentifier.uuidString),
            "type": .string(c.localizedDescription),
            "type_uuid": .string(c.characteristicType),
            "readable": .bool(props.contains(HMCharacteristicPropertyReadable)),
            "writable": .bool(props.contains(HMCharacteristicPropertyWritable)),
            "value": value(c.value, format: c.metadata?.format),
        ]
        if let m = c.metadata {
            if let f = m.format { o["format"] = .string(f) }
            if let u = m.units { o["units"] = .string(u) }
            if let v = m.minimumValue { o["min"] = .number(v.doubleValue) }
            if let v = m.maximumValue { o["max"] = .number(v.doubleValue) }
            if let v = m.stepValue { o["step"] = .number(v.doubleValue) }
            if let v = m.validValues, !v.isEmpty { o["valid_values"] = .array(v.map { .number($0.doubleValue) }) }
        }
        return .object(o)
    }

    static func value(_ v: Any?, format: String?) -> JSONValue {
        guard let v else { return .null }
        if let n = v as? NSNumber, format == HMCharacteristicMetadataFormatBool { return .bool(n.boolValue) }
        if let d = v as? Data { return .string(d.base64EncodedString()) }
        return JSONValue(any: v)
    }

    static func scene(_ s: HMActionSet) -> JSONValue {
        [
            "id": .string(s.uniqueIdentifier.uuidString),
            "name": .string(s.name),
            "type": .string(s.actionSetType),
            "actions": .number(Double(s.actions.count)),
            "executing": .bool(s.isExecuting),
        ]
    }
}

/// Apple Home has no floors. We treat zones as floors (all zones, or only those whose name
/// starts with `floor_zone_prefix`). See docs/FLOORS.md.
enum Floors {
    static func isFloor(_ z: HMZone, prefix: String) -> Bool {
        prefix.isEmpty || z.name.hasPrefix(prefix)
    }

    static func floorName(_ z: HMZone, prefix: String) -> String {
        guard !prefix.isEmpty, z.name.hasPrefix(prefix) else { return z.name }
        return String(z.name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    static func zoneName(forFloor floor: String, prefix: String) -> String {
        // The prefix carries its own separator, e.g. "Floor: " -> "Floor: Upstairs".
        prefix + floor
    }
}
