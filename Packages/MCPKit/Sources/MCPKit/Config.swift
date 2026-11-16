import Foundation
import Security

/// Local, per-machine configuration. Lives outside the repository in
/// `~/Library/Application Support/AppleHomeMCP/config.json` (inside the app container when sandboxed).
/// Secrets (API key, Home Assistant token) are NOT stored here; they live in the Keychain.
public struct AppConfig: Codable, Equatable, Sendable {
    public var port: Int = 8737
    /// Bind to all interfaces instead of 127.0.0.1. Always requires the API key.
    public var exposeOnNetwork: Bool = false
    /// Also require the API key on 127.0.0.1. Recommended; default on.
    public var requireAPIKeyOnLoopback: Bool = true
    /// Extra browser origins allowed to call the endpoint (normally none).
    public var allowedOrigins: [String] = []
    /// Allow control writes (characteristics, scenes) on non-protected accessories.
    public var controlEnabled: Bool = false
    /// Accessories that must never be written to: UUIDs, names, `Room/Name` or `*glob*` patterns.
    public var denylist: [String] = []
    /// Service kinds whose control writes are always refused.
    public var protectedKinds: [String] = SafetyPolicy.defaultProtectedKinds.sorted()
    /// Home to operate on by default (name or UUID). Empty = the primary home.
    public var defaultHome: String = ""
    /// Zones whose name starts with this prefix are treated as floors. Empty = every zone is a floor.
    public var floorZonePrefix: String = ""
    public var homeAssistant: HomeAssistantConfig = HomeAssistantConfig()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case port
        case exposeOnNetwork = "expose_on_network"
        case requireAPIKeyOnLoopback = "require_api_key_on_loopback"
        case allowedOrigins = "allowed_origins"
        case controlEnabled = "control_enabled"
        case denylist
        case protectedKinds = "protected_kinds"
        case defaultHome = "default_home"
        case floorZonePrefix = "floor_zone_prefix"
        case homeAssistant = "home_assistant"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        exposeOnNetwork = try c.decodeIfPresent(Bool.self, forKey: .exposeOnNetwork) ?? d.exposeOnNetwork
        requireAPIKeyOnLoopback = try c.decodeIfPresent(Bool.self, forKey: .requireAPIKeyOnLoopback) ?? d.requireAPIKeyOnLoopback
        allowedOrigins = try c.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? d.allowedOrigins
        controlEnabled = try c.decodeIfPresent(Bool.self, forKey: .controlEnabled) ?? d.controlEnabled
        denylist = try c.decodeIfPresent([String].self, forKey: .denylist) ?? d.denylist
        protectedKinds = try c.decodeIfPresent([String].self, forKey: .protectedKinds) ?? d.protectedKinds
        defaultHome = try c.decodeIfPresent(String.self, forKey: .defaultHome) ?? d.defaultHome
        floorZonePrefix = try c.decodeIfPresent(String.self, forKey: .floorZonePrefix) ?? d.floorZonePrefix
        homeAssistant = try c.decodeIfPresent(HomeAssistantConfig.self, forKey: .homeAssistant) ?? d.homeAssistant
    }

    public var safetyPolicy: SafetyPolicy {
        // Protected kinds can be extended but never reduced below the built-in set.
        SafetyPolicy(denylist: denylist, protectedKinds: SafetyPolicy.defaultProtectedKinds.union(protectedKinds), controlEnabled: controlEnabled)
    }

    public func validated() throws -> AppConfig {
        guard (1024...65535).contains(port) else { throw ToolError("port must be between 1024 and 65535") }
        if !homeAssistant.url.isEmpty {
            guard let u = URL(string: homeAssistant.url), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else {
                throw ToolError("home_assistant.url must be an http(s) URL")
            }
        }
        return self
    }
}

public struct HomeAssistantConfig: Codable, Equatable, Sendable {
    /// Base URL, e.g. https://homeassistant.local:8123. The access token lives in the Keychain.
    public var url: String = ""
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

public final class ConfigStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var cached: AppConfig

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppleHomeMCP", isDirectory: true)
    }

    public init(fileURL: URL = ConfigStore.defaultDirectory.appendingPathComponent("config.json")) {
        self.fileURL = fileURL
        self.cached = AppConfig()
        reload()
    }

    @discardableResult
    public func reload() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cached = AppConfig()
            try? writeLocked(cached)
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            cached = try JSONDecoder().decode(AppConfig.self, from: data).validated()
            return nil
        } catch {
            // Keep the previous config and fail safe: control stays as it was, denylist stays.
            return "config.json is invalid (\(error)); keeping previous settings"
        }
    }

    public var config: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func update(_ mutate: (inout AppConfig) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var c = cached
        mutate(&c)
        c = try c.validated()
        try writeLocked(c)
        cached = c
    }

    private func writeLocked(_ c: AppConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(c).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Generic-password Keychain storage for the API key and Home Assistant token.
public enum Keychain {
    public static let service = "apple-home-mcp"
    /// Last OSStatus from a failed call, for diagnostics.
    nonisolated(unsafe) public static var lastStatus: OSStatus = errSecSuccess

    /// Use the file-based login keychain on every platform variant (Mac Catalyst would otherwise
    /// default to the data-protection keychain), so the stdio bridge CLI can read the same item.
    static func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS) || targetEnvironment(macCatalyst)
        q[kSecUseDataProtectionKeychain as String] = false
        #endif
        return q
    }

    public static func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func write(_ account: String, _ value: String) -> Bool {
        let q = base(account)
        let data = Data(value.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Apple Home MCP (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        lastStatus = status
        return status == errSecSuccess
    }

    @discardableResult
    public static func delete(_ account: String) -> Bool {
        let q = base(account)
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }

    public static let apiKeyAccount = "mcp-api-key"
    public static let homeAssistantTokenAccount = "home-assistant-token"
}
