import Foundation
import HomeKit
import MCPKit
import UIKit

@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    static weak var shared: AppDelegate?

    let config = ConfigStore()
    let store = HomeStore()
    let matter = MatterBridge()
    lazy var host = AppHost(config: config, store: store, matter: matter)
    var menuBar: MenuBarPlugin?
    private var activity: NSObjectProtocol?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppDelegate.shared = self
        // Keep the server responsive while the app sits in the background (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Serving MCP requests for Apple Home")
        host.start()
        loadMenuBar()
        appLog.info("Apple Home MCP started")
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }

    private func loadMenuBar() {
        #if targetEnvironment(macCatalyst)
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MenuBar.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let cls = bundle.principalClass as? NSObject.Type,
              let plugin = cls.init() as? MenuBarPlugin
        else {
            appLog.error("could not load MenuBar.bundle")
            return
        }
        plugin.start(host: host)
        menuBar = plugin
        #endif
    }
}

/// Glue between HomeKit, the MCP server, the config and the menu bar.
@MainActor
final class AppHost: NSObject, MenuBarHost {
    let config: ConfigStore
    let store: HomeStore
    let matter: MatterBridge
    private var http: HTTPServer?
    private var mcp: MCPServer!
    private var serverState = "starting"
    private var activityLog: [String] = []
    private var cachedKey: String?
    private var tools: HomeTools!

    init(config: ConfigStore, store: HomeStore, matter: MatterBridge) {
        self.config = config
        self.store = store
        self.matter = matter
        super.init()
    }

    func start() {
        importHomeAssistantFromEnvironment()
        cachedKey = Keychain.read(Keychain.apiKeyAccount)
        if cachedKey == nil {
            let k = APIKey.generate()
            if Keychain.write(Keychain.apiKeyAccount, k) { cachedKey = k } else {
                appLog.error("could not store API key in Keychain: OSStatus \(Keychain.lastStatus, privacy: .public)")
                record("Keychain write failed (\(Keychain.lastStatus))")
            }
        }
        tools = HomeTools(store: store, matter: matter, config: config) { [weak self] line in
            Task { @MainActor in self?.record(line) }
        }
        let instructions = """
        Apple Home (HomeKit) on this Mac. Read freely. Organizing (rename, rooms, zones, floors) writes to the user's real \
        home: say what you will change first. Pairing/sharing and deletes need confirm=true, which you may only set after \
        the human approved that exact action. Locks, garage doors, security systems and denylisted accessories are never \
        controlled. Floors are modelled as zones. Typical onboarding: add_accessory -> human adds it on iPhone -> \
        wait_for_new_accessory -> rename_accessory/move_accessory -> matter_share_to_home_assistant -> ha_sync_areas.
        """
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        mcp = MCPServer(name: "apple-home-mcp", version: version, instructions: instructions) { [config, weak self] in
            let c = config.config
            return AccessPolicy(networkExposed: c.exposeOnNetwork, requireKeyOnLoopback: c.requireAPIKeyOnLoopback,
                                apiKey: self?.keySnapshot, allowedOrigins: c.allowedOrigins)
        }
        mcp.register(tools.all())
        mcp.onToolCall = { [weak self] name, ok in
            Task { @MainActor in self?.record("\(name)\(ok ? "" : " (error)")") }
        }
        store.onChange = { [weak self] in self?.menuRefresh() }
        restartServer()
    }

    /// One-time import of an existing token: `open --env AHM_HA_URL=... --env AHM_HA_TOKEN="$HA_TOKEN" "Apple Home MCP.app"`.
    /// The token goes straight into the Keychain and is never logged or written to the config file.
    private func importHomeAssistantFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if let url = env["AHM_HA_URL"], !url.isEmpty { try? config.update { $0.homeAssistant.url = url } }
        if let token = env["AHM_HA_TOKEN"], !token.isEmpty {
            if Keychain.write(Keychain.homeAssistantTokenAccount, token) { record("Home Assistant token imported") }
            else { record("Home Assistant token import failed (\(Keychain.lastStatus))") }
        }
    }

    nonisolated(unsafe) private var _keySnapshot: String?
    nonisolated var keySnapshot: String? { _keySnapshot }

    private func record(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        activityLog.append("\(f.string(from: Date()))  \(line)")
        if activityLog.count > 100 { activityLog.removeFirst(activityLog.count - 100) }
    }

    private func menuRefresh() { AppDelegate.shared?.menuBar?.refresh() }

    func restartServer() {
        _keySnapshot = cachedKey
        http?.stop()
        let c = config.config
        let server = HTTPServer(port: UInt16(c.port), bind: c.exposeOnNetwork ? .allInterfaces : .loopback) { [mcp] req in
            await mcp!.handleHTTP(req)
        }
        server.onStateChange = { [weak self] s in Task { @MainActor in self?.serverState = s } }
        do {
            try server.start()
            http = server
        } catch {
            serverState = "failed: \(error.localizedDescription)"
        }
    }

    // MARK: MenuBarHost

    var statusLine: String {
        let c = config.config
        let where_ = c.exposeOnNetwork ? "all interfaces" : "127.0.0.1"
        return serverState == "listening" ? "Listening on \(where_):\(c.port)" : "Server: \(serverState)"
    }

    var homeLine: String {
        guard store.homesLoaded else { return "HomeKit: \(store.authorizationDescription), loading…" }
        let homes = store.manager.homes.count
        return "\(homes) home\(homes == 1 ? "" : "s") · \(store.accessoryCount) accessories"
    }

    var endpointURL: String {
        let c = config.config
        if c.exposeOnNetwork {
            let host = ProcessInfo.processInfo.hostName
            return "http://\(host):\(c.port)/mcp"
        }
        return "http://127.0.0.1:\(c.port)/mcp"
    }

    var apiKey: String? { cachedKey }
    var exposeOnNetwork: Bool { config.config.exposeOnNetwork }
    var requireKeyOnLoopback: Bool { config.config.requireAPIKeyOnLoopback }
    var controlEnabled: Bool { config.config.controlEnabled }
    var homeAssistantURL: String { config.config.homeAssistant.url }
    var homeAssistantTokenSet: Bool { Keychain.read(Keychain.homeAssistantTokenAccount) != nil }
    var configFilePath: String { config.fileURL.path }

    func regenerateAPIKey() {
        let k = APIKey.generate()
        if Keychain.write(Keychain.apiKeyAccount, k) {
            cachedKey = k
            _keySnapshot = k
            record("API key regenerated")
        }
    }

    func setExposeOnNetwork(_ on: Bool) {
        if on && cachedKey == nil { regenerateAPIKey() }
        try? config.update { $0.exposeOnNetwork = on }
        record(on ? "exposed on network" : "loopback only")
        restartServer()
    }

    func setRequireKeyOnLoopback(_ on: Bool) {
        try? config.update { $0.requireAPIKeyOnLoopback = on }
    }

    func setControlEnabled(_ on: Bool) {
        try? config.update { $0.controlEnabled = on }
        record(on ? "control writes enabled" : "control writes disabled")
    }

    func setHomeAssistant(url: String, token: String?) -> String? {
        do {
            try config.update { $0.homeAssistant.url = url }
        } catch {
            return "\(error)"
        }
        if let token, !Keychain.write(Keychain.homeAssistantTokenAccount, token) { return "could not store the token in the Keychain" }
        if url.isEmpty { Keychain.delete(Keychain.homeAssistantTokenAccount) }
        return nil
    }

    func reloadConfig() -> String? {
        let before = config.config
        if let err = config.reload() { return err }
        let after = config.config
        if before.port != after.port || before.exposeOnNetwork != after.exposeOnNetwork { restartServer() }
        return nil
    }

    func recentActivity() -> [String] { activityLog }
}
