import Foundation

/// Facts about an accessory the safety policy needs. Built by the app from HomeKit objects.
public struct AccessoryFacts: Sendable, Equatable {
    public var id: String
    public var name: String
    public var room: String?
    /// Safety-relevant kinds detected from services/category, e.g. "lock", "garage_door", "security_system".
    public var protectedKinds: Set<String>

    public init(id: String, name: String, room: String?, protectedKinds: Set<String>) {
        self.id = id
        self.name = name
        self.room = room
        self.protectedKinds = protectedKinds
    }
}

public enum WriteKind: String, Sendable {
    /// Changing an accessory's state (characteristic writes, scene execution).
    case control
    /// Renaming / moving between rooms.
    case organize
    /// Sharing to another Matter ecosystem (opening a commissioning window).
    case share
}

public enum PolicyDecision: Equatable, Sendable {
    case allow
    case deny(String)

    public var isAllowed: Bool { self == .allow }
}

/// The write-safety policy.
///
/// * Accessories on the local denylist: every write is refused (control, organize, share).
/// * Locks, garage doors, security systems ("protected kinds"): control writes are always
///   refused. Organizing (rename / room) and sharing stay possible because they do not change
///   the physical state and are needed when onboarding a new lock.
/// * Control writes on anything else require `control_enabled` in the local config.
public struct SafetyPolicy: Sendable {
    public static let defaultProtectedKinds: Set<String> = ["lock", "garage_door", "security_system"]

    public var denylist: [String]
    public var protectedKinds: Set<String>
    public var controlEnabled: Bool

    public init(denylist: [String], protectedKinds: Set<String> = SafetyPolicy.defaultProtectedKinds, controlEnabled: Bool) {
        self.denylist = denylist
        self.protectedKinds = protectedKinds
        self.controlEnabled = controlEnabled
    }

    public func evaluate(_ accessory: AccessoryFacts, _ kind: WriteKind) -> PolicyDecision {
        if let entry = denylistMatch(accessory) {
            return .deny("'\(accessory.name)' is on the local denylist (entry '\(entry)'); all writes to it are refused")
        }
        if kind == .control {
            let hit = accessory.protectedKinds.intersection(protectedKinds)
            if !hit.isEmpty {
                return .deny("'\(accessory.name)' is a protected accessory (\(hit.sorted().joined(separator: ", "))); control writes are always refused")
            }
            if !controlEnabled {
                return .deny("control writes are disabled; set \"control_enabled\": true in the local config to allow them")
            }
        }
        return .allow
    }

    /// Returns the denylist entry that matches, if any.
    ///
    /// Entry forms: an accessory UUID, an exact name (`Front Door`), `Room/Name`, or a glob
    /// with `*` (`*garage*`). Matching ignores case and diacritics and treats ä/ö/ü/ß as ae/oe/ue/ss.
    public func denylistMatch(_ accessory: AccessoryFacts) -> String? {
        let name = SafetyPolicy.normalize(accessory.name)
        let qualified = accessory.room.map { SafetyPolicy.normalize($0) + "/" + name }
        for raw in denylist {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.isEmpty { continue }
            if entry.caseInsensitiveCompare(accessory.id) == .orderedSame { return raw }
            let pattern = SafetyPolicy.normalize(entry)
            if SafetyPolicy.glob(pattern, matches: name) { return raw }
            if let qualified, SafetyPolicy.glob(pattern, matches: qualified) { return raw }
        }
        return nil
    }

    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let collapsed = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }

    /// `*` matches any run of characters; everything else is literal.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern), s = Array(text)
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count && p[pi] != "*" && p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
