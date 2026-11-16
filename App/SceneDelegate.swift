import UIKit

/// The app never shows UI of its own (the menu bar plugin is the UI). UIKit on Mac Catalyst
/// still creates a scene at launch; we attach a tiny transparent window to it so that the
/// process counts as having a live scene, and the menu bar plugin keeps it ordered out.
/// See docs/BACKGROUND.md for why and what was measured.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Diagnostics: `-AHMNoWindow YES` skips the helper window (see docs/BACKGROUND.md).
        if UserDefaults.standard.bool(forKey: "AHMNoWindow") { return }
        #if targetEnvironment(macCatalyst)
        windowScene.titlebar?.titleVisibility = .hidden
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1, height: 1)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1, height: 1)
        #endif
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        window.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.isHidden = false
        self.window = window
        AppDelegate.shared?.menuBar?.refresh()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppDelegate.shared?.menuBar?.refresh()
    }
}
