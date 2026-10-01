// swift-tools-version:6.0
import PackageDescription

// Reached only transitively: `Core` -> `../SwiftMapper` -> `../Logging`.
let package = Package(
    name: "Logging",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Logging", targets: ["Logging"])],
    targets: [.target(name: "Logging")]
)
