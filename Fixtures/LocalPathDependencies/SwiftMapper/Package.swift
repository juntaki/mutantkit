// swift-tools-version:6.0
import PackageDescription

// Sibling of `Core`, reached from it by `../SwiftMapper`. Depends on a
// further sibling so the dependency graph is transitive.
let package = Package(
    name: "SwiftMapper",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SwiftMapper", targets: ["SwiftMapper"])],
    dependencies: [.package(path: "../Logging")],
    targets: [
        .target(name: "SwiftMapper", dependencies: [.product(name: "Logging", package: "Logging")]),
    ]
)
