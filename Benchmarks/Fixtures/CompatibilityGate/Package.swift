// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CompatibilityGate",
    targets: [
        .target(name: "CompatibilityGate"),
        .testTarget(name: "CompatibilityGateTests", dependencies: ["CompatibilityGate"])
    ]
)
