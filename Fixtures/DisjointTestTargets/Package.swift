// swift-tools-version:6.0
import PackageDescription

// Two libraries, each tested by its own test target and linked into only that target's test bundle.
// SwiftPM's own coverage export is made against one bundle, so this shape shows whether the
// coverage of the *other* target's tests is lost.
let package = Package(
    name: "DisjointTestTargets",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Alpha", targets: ["Alpha"]),
        .library(name: "Beta", targets: ["Beta"]),
    ],
    targets: [
        .target(name: "Alpha"),
        .target(name: "Beta"),
        .testTarget(name: "AlphaTests", dependencies: ["Alpha"]),
        .testTarget(name: "BetaTests", dependencies: ["Beta"]),
    ]
)
