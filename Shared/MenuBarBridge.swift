import Foundation

// Compiled into both the Mac Catalyst app and the AppKit MenuBar.bundle. The explicit
// Objective-C names make the runtime treat both copies as the same protocol.

/// Implemented by the Catalyst app, consumed by the AppKit status item.
@objc(AHMMenuBarHost)
public protocol MenuBarHost: NSObjectProtocol {
    /// One-line status, e.g. "Listening on 127.0.0.1:8737".
    var statusLine: String { get }
    /// Second line, e.g. "1 home · 42 accessories".
    var homeLine: String { get }
    var endpointURL: String { get }
    var apiKey: String? { get }
    var exposeOnNetwork: Bool { get }
    var requireKeyOnLoopback: Bool { get }
    var controlEnabled: Bool { get }
    var homeAssistantURL: String { get }
    var homeAssistantTokenSet: Bool { get }
    var configFilePath: String { get }

    func regenerateAPIKey()
    func setExposeOnNetwork(_ on: Bool)
    func setRequireKeyOnLoopback(_ on: Bool)
    func setControlEnabled(_ on: Bool)
    /// Pass nil token to keep the stored token.
    func setHomeAssistant(url: String, token: String?) -> String?
    func reloadConfig() -> String?
    func recentActivity() -> [String]
}

/// Implemented by the MenuBar.bundle principal class.
@objc(AHMMenuBarPlugin)
public protocol MenuBarPlugin: NSObjectProtocol {
    init()
    func start(host: MenuBarHost)
    func refresh()
}
