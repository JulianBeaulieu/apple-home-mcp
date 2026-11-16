import AppKit
import ServiceManagement

/// AppKit side of the app: the status item and its menu. Loaded at runtime by the Catalyst app
/// (Mac Catalyst cannot create an NSStatusItem itself).
@objc(AHMMenuBarPluginImpl)
final class MenuBarPluginImpl: NSObject, MenuBarPlugin, NSMenuDelegate {
    private var host: MenuBarHost?
    private var statusItem: NSStatusItem?

    override required init() { super.init() }

    func start(host: MenuBarHost) {
        self.host = host
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "house.circle", accessibilityDescription: "Apple Home MCP")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Apple Home MCP"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        hideCatalystWindows()
    }

    func refresh() {
        hideCatalystWindows()
    }

    /// The Catalyst scene may create an NSWindow; we never want one on screen.
    private func hideCatalystWindows() {
        for w in NSApp.windows where !(w is NSPanel) && w.className != "NSStatusBarWindow" {
            if w.isVisible { w.orderOut(nil) }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let host else { return }
        menu.addItem(disabled(host.statusLine))
        menu.addItem(disabled(host.homeLine))
        menu.addItem(.separator())
        menu.addItem(action("Copy MCP URL", #selector(copyURL)))
        menu.addItem(action("Copy Claude Code setup command", #selector(copyClaudeCommand)))
        menu.addItem(action(host.apiKey == nil ? "Generate API key" : "Copy API key", #selector(copyKey)))
        menu.addItem(action("Regenerate API key…", #selector(regenerateKey)))
        menu.addItem(.separator())
        menu.addItem(toggle("Expose on network (requires API key)", host.exposeOnNetwork, #selector(toggleExpose)))
        menu.addItem(toggle("Require API key on localhost", host.requireKeyOnLoopback, #selector(toggleLoopbackKey)))
        menu.addItem(toggle("Allow control writes (non-protected accessories)", host.controlEnabled, #selector(toggleControl)))
        menu.addItem(action(host.homeAssistantTokenSet ? "Home Assistant… (connected)" : "Home Assistant…", #selector(configureHA)))
        menu.addItem(.separator())
        let activity = NSMenuItem(title: "Recent activity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let lines = host.recentActivity()
        if lines.isEmpty { sub.addItem(disabled("No tool calls yet")) }
        for l in lines.suffix(15).reversed() { sub.addItem(disabled(l)) }
        activity.submenu = sub
        menu.addItem(activity)
        menu.addItem(action("Open config file", #selector(openConfig)))
        menu.addItem(action("Reload config", #selector(reloadConfig)))
        menu.addItem(toggle("Launch at login", SMAppService.mainApp.status == .enabled, #selector(toggleLoginItem)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Apple Home MCP", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = action(title, sel)
        i.state = on ? .on : .off
        return i
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func copyURL() { copy(host?.endpointURL ?? "") }

    @objc private func copyKey() {
        guard let host else { return }
        if host.apiKey == nil { host.regenerateAPIKey() }
        copy(host.apiKey ?? "")
    }

    @objc private func copyClaudeCommand() {
        guard let host else { return }
        var cmd = "claude mcp add --transport http apple-home \(host.endpointURL)"
        if let key = host.apiKey { cmd += " --header \"Authorization: Bearer \(key)\"" }
        copy(cmd)
    }

    @objc private func regenerateKey() {
        guard confirm("Regenerate the API key?", "Every MCP client using the old key will stop working until you update it.") else { return }
        host?.regenerateAPIKey()
    }

    @objc private func toggleExpose() {
        guard let host else { return }
        if !host.exposeOnNetwork {
            guard confirm("Expose Apple Home MCP on your network?",
                          "The server will listen on all interfaces. Every request must carry the API key. Traffic is plain HTTP: put it behind a TLS reverse proxy (see docs/SECURITY.md) or only use it on a trusted network.") else { return }
        }
        host.setExposeOnNetwork(!host.exposeOnNetwork)
    }

    @objc private func toggleLoopbackKey() {
        guard let host else { return }
        host.setRequireKeyOnLoopback(!host.requireKeyOnLoopback)
    }

    @objc private func toggleControl() {
        guard let host else { return }
        if !host.controlEnabled {
            guard confirm("Allow control writes?",
                          "Agents will be able to switch accessories and run scenes. Locks, garage doors, security systems and everything on your denylist stay blocked.") else { return }
        }
        host.setControlEnabled(!host.controlEnabled)
    }

    @objc private func configureHA() {
        guard let host else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Home Assistant"
        alert.informativeText = "Base URL (e.g. https://homeassistant.local:8123) and a long-lived access token. The token is stored in your Keychain. Leave the token empty to keep the current one."
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 56))
        stack.orientation = .vertical
        stack.spacing = 8
        let urlField = NSTextField(string: host.homeAssistantURL)
        urlField.placeholderString = "https://homeassistant.local:8123"
        let tokenField = NSSecureTextField(string: "")
        tokenField.placeholderString = host.homeAssistantTokenSet ? "•••••• (stored)" : "Long-lived access token"
        for f in [urlField, tokenField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 360).isActive = true
            stack.addArrangedSubview(f)
        }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = urlField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = host.setHomeAssistant(url: urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), token: token.isEmpty ? nil : token) {
            inform("Could not save Home Assistant settings", err)
        }
    }

    @objc private func openConfig() {
        guard let path = host?.configFilePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func reloadConfig() {
        if let err = host?.reloadConfig() { inform("Config not reloaded", err) }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            inform("Launch at login", error.localizedDescription)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func confirm(_ title: String, _ text: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func inform(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
