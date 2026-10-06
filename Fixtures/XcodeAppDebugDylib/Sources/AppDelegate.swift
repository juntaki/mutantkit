import UIKit

/// Mixed test quality, same as the other fixtures: the acceptance test asserts
/// which of these mutants must die and which must survive. Its code has to
/// live in the `application` target itself — not a framework it links against
/// — so a mutation here lands in the loose debug dylib this fixture exists to
/// exercise.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Boundary-tested. Its mutants should be killed.
    static func isInStock(count: Int) -> Bool {
        count >= 1
    }

    /// Untested. Its mutants should survive.
    static func requiresConfirmation(itemCount: Int) -> Bool {
        itemCount > 5
    }

    /// Scene lifecycle: the iOS 27 SDK refuses to launch apps without it, and
    /// the same code runs unchanged on earlier runtimes.
    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
