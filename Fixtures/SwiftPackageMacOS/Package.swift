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
    ]
)
