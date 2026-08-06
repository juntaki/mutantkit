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
}
