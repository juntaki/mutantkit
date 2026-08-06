// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture: a package with a mutation that hangs forever.
//
// Mutation testing routinely produces non-terminating mutants — deleting a
// `continuation.resume()` is the canonical Swift example — so the tool must
// always terminate anyway. This fixture makes that failure reproducible on
// demand rather than waiting for it to appear in someone's real project.
let package = Package(
    name: "Spin",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Spin", targets: ["Spin"])],
    targets: [
        .target(name: "Spin"),
        .testTarget(name: "SpinTests", dependencies: ["Spin"]),
    ]
)
