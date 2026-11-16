import CryptoKit
import Foundation
import Security

public enum APIKey {
    /// 32 random bytes, base64url without padding, prefixed for easy recognition by secret scanners.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "ahmcp_" + b64
    }

    /// Constant-time comparison. Both sides are hashed first so timing does not leak length either.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let da = SHA256.hash(data: Data(a.utf8))
        let db = SHA256.hash(data: Data(b.utf8))
        var diff: UInt8 = 0
        for (x, y) in zip(da, db) { diff |= x ^ y }
        return diff == 0
    }

    /// Extracts the token from an `Authorization: Bearer <token>` header value.
    public static func bearerToken(from header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

/// Request-level access checks for the MCP endpoint.
public struct AccessPolicy: Sendable {
    public var networkExposed: Bool
    public var requireKeyOnLoopback: Bool
    public var apiKey: String?
    public var allowedOrigins: [String]

    public init(networkExposed: Bool, requireKeyOnLoopback: Bool, apiKey: String?, allowedOrigins: [String] = []) {
        self.networkExposed = networkExposed
        self.requireKeyOnLoopback = requireKeyOnLoopback
        self.apiKey = apiKey
        self.allowedOrigins = allowedOrigins
    }

    public enum Verdict: Equatable, Sendable {
        case allow
        case deny(status: Int, reason: String)
    }

    static func isLoopbackHost(_ hostHeader: String) -> Bool {
        var host = hostHeader.lowercased()
        if host.hasPrefix("[") {
            if let end = host.firstIndex(of: "]") { host = String(host[host.index(after: host.startIndex)..<end]) }
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    public func evaluate(_ request: HTTPRequest) -> Verdict {
        // DNS-rebinding protection (MCP spec): browsers always send Origin; reject foreign origins.
        if let origin = request.header("origin") {
            let allowed = AccessPolicy.isLoopbackOrigin(origin) || allowedOrigins.contains(origin)
            if !allowed { return .deny(status: 403, reason: "origin not allowed") }
        }
        if !networkExposed {
            // In loopback mode only accept loopback Host headers (defeats DNS rebinding to 127.0.0.1).
            if let host = request.header("host"), !AccessPolicy.isLoopbackHost(host) {
                return .deny(status: 403, reason: "host not allowed")
            }
        }
        let keyRequired = networkExposed || requireKeyOnLoopback
        guard keyRequired else { return .allow }
        guard let expected = apiKey, !expected.isEmpty else {
            return .deny(status: 401, reason: "API key required but none configured; generate one in the menu bar app")
        }
        guard let presented = AccessPolicy.presentedKey(request), APIKey.constantTimeEquals(presented, expected) else {
            return .deny(status: 401, reason: "missing or invalid bearer token")
        }
        return .allow
    }

    static func presentedKey(_ request: HTTPRequest) -> String? {
        if let t = APIKey.bearerToken(from: request.header("authorization")) { return t }
        return request.header("x-api-key")
    }
}
