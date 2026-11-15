import UIKit
import ZTronSearchEngineUIParity

// The parity host app: a window whose root is the parity stage. Everything else lives in the
// ZTronSearchEngineUIParity library, so the app, the UI tests and the package tests share it.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Parity", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = ParityWindow(windowScene: windowScene)
        window.rootViewController = ParityHost.makeRootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
