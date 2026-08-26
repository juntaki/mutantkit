import SwiftUI

/// Gate 3 Phase H8: a minimal, real, launchable iOS app — not a bare
/// framework — existing only so `HangAppTests` can be an *app-hosted* unit
/// test bundle (`IsAppHostedTestBundle: true`, sharing this app's own main
/// thread/run loop), the structural property confirmed (Gate 3 Phase H8)
/// to distinguish a real, large production iOS app (whose own unit-test
/// bundle is app-hosted against its own app binary) from every earlier
/// synthetic hang fixture in this gate (`CheckoutTests`/
/// `HangContainmentTests`, both hosted by the generic `xctest` runner, no
/// real app process at all).
@main
struct HangAppApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Gate 3 Phase H8 fixture")
        }
    }
}
