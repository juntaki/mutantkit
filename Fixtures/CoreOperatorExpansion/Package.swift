// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture exercising the six operators added by PR #6 (ternary
// branch swap, unary-not removal, nil-coalescing fallback, return-value
// replacement, arithmetic replacement, assignment replacement) through the
// real plan -> sandbox -> apply -> build -> test -> classify pipeline, not
// just isolated `swiftc -typecheck` snippets.
let package = Package(
    name: "Ops",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Ops", targets: ["Ops"])],
    targets: [
        .target(name: "Ops"),
        .testTarget(name: "OpsTests", dependencies: ["Ops"]),
    ]
)
