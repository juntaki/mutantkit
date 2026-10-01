// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture: the project under test depends on a sibling package
// by relative path, and that sibling depends on a further sibling. Only
// `Core` is mutated; `SwiftMapper` and `Logging` are build inputs that
// every sandbox must carry at the same relative placement.
let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Core", targets: ["Core"])],
    dependencies: [.package(path: "../SwiftMapper")],
    targets: [
        .target(name: "Core", dependencies: [.product(name: "SwiftMapper", package: "SwiftMapper")]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
