import UIKit

/// Boundary-tested by a unit test only — no UI test ever exercises this
/// method. A mutation here must narrow, via `selectCoveringTests`, to a
/// selection containing only `BatchUIDemoTests` identifiers.
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
