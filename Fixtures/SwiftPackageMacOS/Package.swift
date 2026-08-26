// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture: a host-testable Swift package. This is the one project
// kind that runs end-to-end on any macOS machine with no simulator and no
// signing, which makes it the fixture the pipeline is proven against in CI.
let package = Package(
    name: "Pricing",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Pricing", targets: ["Pricing"])],
    targets: [
        .target(name: "Pricing"),
        .testTarget(name: "PricingTests", dependencies: ["Pricing"]),
        // Phase C2 (competitive-parity program): proves SwiftPM + XCTest is
        // real acceptance-tested end to end, not merely a code path that
        // exists. Every other SwiftPM/macOS fixture in this repo
        // (`SwiftPackageMacOS` itself, `CoreOperatorExpansion`,
        // `HangingMutant`) uses Swift Testing exclusively -- this was a real
        // gap, not a deliberate one. Separate target, not mixed into
        // `PricingTests`, so `tests.targets` can point at exactly one
        // framework and the two never share a coverage universe.
        .testTarget(name: "PricingXCTestTests", dependencies: ["Pricing"]),
    ]
)
