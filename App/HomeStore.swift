import Foundation
import HomeKit
import MCPKit
import os

let appLog = Logger(subsystem: "apple-home-mcp", category: "app")

/// Owns the HMHomeManager and resolves user-supplied names/ids to HomeKit objects.
@MainActor
final class HomeStore: NSObject, HMHomeManagerDelegate, HMHomeDelegate {
    let manager = HMHomeManager()
    private(set) var homesLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Accessories added while we were running: (home id, accessory id, time).
    private(set) var addedAccessories: [(home: UUID, accessory: UUID, at: Date)] = []
    private var addWaiters: [UUID: (Date, CheckedContinuation<Void, Never>)] = [:]
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: Loading

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        MainActor.assumeIsolated {
            homesLoaded = true
            for h in manager.homes { h.delegate = self }
            let w = loadWaiters
            loadWaiters.removeAll()
            w.forEach { $0.resume() }
            onChange?()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        MainActor.assumeIsolated {
            home.delegate = self
            onChange?()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        MainActor.assumeIsolated { onChange?() }
    }

    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        MainActor.assumeIsolated {
            addedAccessories.append((home.uniqueIdentifier, accessory.uniqueIdentifier, Date()))
            if addedAccessories.count > 50 { addedAccessories.removeFirst(addedAccessories.count - 50) }
            let ready = addWaiters
            addWaiters.removeAll()
            ready.values.forEach { $0.1.resume() }
            onChange?()
        }
    }

    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        MainActor.assumeIsolated { onChange?() }
    }

    func waitUntilLoaded(timeout: TimeInterval = 20) async throws {
        if homesLoaded { return }
        let status = manager.authorizationStatus
        if status.contains(.determined) && !status.contains(.authorized) {
            throw ToolError("HomeKit access was denied. Allow it in System Settings › Privacy & Security › HomeKit.")
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            let w = loadWaiters
            loadWaiters.removeAll()
            w.forEach { $0.resume() }
        }
        await withCheckedContinuation { loadWaiters.append($0) }
        timer.cancel()
        if !homesLoaded {
            throw ToolError("HomeKit did not deliver homes within \(Int(timeout))s (authorization: \(authorizationDescription)). Is this Mac signed into iCloud with Home enabled?")
        }
    }

    /// Waits for HMHomeDelegate.didAdd after `since`. Returns the accessory or nil on timeout.
    func waitForNewAccessory(home: HMHome, since: Date, timeout: TimeInterval) async -> HMAccessory? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let hit = addedAccessories.last(where: { $0.home == home.uniqueIdentifier && $0.at >= since }),
               let acc = home.accessories.first(where: { $0.uniqueIdentifier == hit.accessory }) {
                return acc
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            let token = UUID()
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, 5) * 1_000_000_000))
                if let w = addWaiters.removeValue(forKey: token) { w.1.resume() }
            }
            await withCheckedContinuation { addWaiters[token] = (Date(), $0) }
            timer.cancel()
        }
    }

    var authorizationDescription: String {
        let s = manager.authorizationStatus
        if s.contains(.authorized) { return "authorized" }
        if s.contains(.determined) { return "denied" }
        return "not determined"
    }

    var accessoryCount: Int { manager.homes.reduce(0) { $0 + $1.accessories.count } }

    // MARK: Resolution

    func home(_ ref: String?, defaultHome: String) async throws -> HMHome {
        try await waitUntilLoaded()
        let homes = manager.homes
        guard !homes.isEmpty else { throw ToolError("no homes found for this Apple ID") }
        let wanted = (ref?.isEmpty == false ? ref : nil) ?? (defaultHome.isEmpty ? nil : defaultHome)
        guard let wanted else {
            if #available(macCatalyst 16.1, *) {
                return homes.first(where: { $0.isPrimary }) ?? homes[0]
            }
            return homes[0]
        }
        if let h = homes.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) { return h }
        let matches = homes.filter { SafetyPolicy.normalize($0.name) == SafetyPolicy.normalize(wanted) }
        if matches.count == 1 { return matches[0] }
        throw ToolError("home '\(wanted)' not found", details: .array(homes.map { .string($0.name) }))
    }

    func accessory(_ ref: String, in home: HMHome) throws -> HMAccessory {
        try resolve(ref, in: home.accessories, kind: "accessory", name: { $0.name }, id: { $0.uniqueIdentifier },
                    describe: { "\($0.name) (\($0.room?.name ?? "no room"), id \($0.uniqueIdentifier.uuidString))" })
    }

    func room(_ ref: String, in home: HMHome) throws -> HMRoom {
        let all = home.rooms + [home.roomForEntireHome()]
        return try resolve(ref, in: all, kind: "room", name: { $0.name }, id: { $0.uniqueIdentifier }, describe: { $0.name })
    }

    func zone(_ ref: String, in home: HMHome) throws -> HMZone {
        try resolve(ref, in: home.zones, kind: "zone", name: { $0.name }, id: { $0.uniqueIdentifier }, describe: { $0.name })
    }

    func scene(_ ref: String, in home: HMHome) throws -> HMActionSet {
        try resolve(ref, in: home.actionSets, kind: "scene", name: { $0.name }, id: { $0.uniqueIdentifier }, describe: { $0.name })
    }

    private func resolve<T>(_ ref: String, in items: [T], kind: String, name: (T) -> String, id: (T) -> UUID, describe: (T) -> String) throws -> T {
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = items.first(where: { id($0).uuidString.caseInsensitiveCompare(r) == .orderedSame }) { return hit }
        let key = SafetyPolicy.normalize(r)
        let exact = items.filter { SafetyPolicy.normalize(name($0)) == key }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            throw ToolError("\(kind) name '\(r)' is ambiguous; pass the id instead", details: .array(exact.map { .string(describe($0)) }))
        }
        let partial = items.filter { SafetyPolicy.normalize(name($0)).contains(key) }
        if partial.count == 1 { return partial[0] }
        throw ToolError(partial.isEmpty ? "\(kind) '\(r)' not found" : "\(kind) '\(r)' matches several; pass the exact name or id",
                        details: partial.isEmpty ? nil : .array(partial.prefix(20).map { .string(describe($0)) }))
    }
}

// MARK: - Safety facts

enum Protected {
    static let serviceKinds: [String: String] = [
        HMServiceTypeLockMechanism: "lock",
        HMServiceTypeLockManagement: "lock",
        HMServiceTypeGarageDoorOpener: "garage_door",
        HMServiceTypeSecuritySystem: "security_system",
    ]
    static let categoryKinds: [String: String] = [
        HMAccessoryCategoryTypeDoorLock: "lock",
        HMAccessoryCategoryTypeGarageDoorOpener: "garage_door",
        HMAccessoryCategoryTypeSecuritySystem: "security_system",
    ]
    /// Characteristics that are never written, whatever service they appear on.
    static let characteristicTypes: Set<String> = [
        HMCharacteristicTypeTargetLockMechanismState,
        HMCharacteristicTypeTargetDoorState,
        HMCharacteristicTypeTargetSecuritySystemState,
        HMCharacteristicTypeLockManagementControlPoint,
    ]

    static func kinds(_ a: HMAccessory) -> Set<String> {
        var k = Set<String>()
        for s in a.services { if let x = serviceKinds[s.serviceType] { k.insert(x) } }
        if let x = categoryKinds[a.category.categoryType] { k.insert(x) }
        return k
    }

    static func facts(_ a: HMAccessory) -> AccessoryFacts {
        AccessoryFacts(id: a.uniqueIdentifier.uuidString, name: a.name, room: a.room?.name, protectedKinds: kinds(a))
    }
}
