// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture for Finding D (P12-B): `measurePerTestCoverage`'s
// per-test loop must never silently downgrade "this test's coverage run
// could not be proven" into "this test covers nothing". `widgetBNeverProfiles`
// below fails deterministically every time it is run in isolation, on
// purpose and unconditionally. XCTest, not Swift Testing -- SwiftPM filters
// XCTest itself rather than at runtime, so this fixture's per-test isolation
// is unaffected by the separate Swift Testing filter-escaping bug tracked
// elsewhere in this investigation, and keeps proving the fail-closed
// contract before, during and after that filter bug is fixed.
let package = Package(
    name: "Widgets",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Widgets", targets: ["Widgets"])],
    targets: [
        .target(name: "Widgets"),
        .testTarget(name: "WidgetsTests", dependencies: ["Widgets"])
    ]
)
