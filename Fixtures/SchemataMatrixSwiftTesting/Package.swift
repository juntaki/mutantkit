// swift-tools-version:6.0
import PackageDescription

// Schemata supported-matrix fixture: SwiftPM macOS + Swift Testing. See
// Fixtures/SchemataMatrixXCTest/Package.swift's own comment for why this
// fixture is fully covered (zero uncovered candidates) rather than
// deliberately partial like Fixtures/SchemataSwiftPackageMacOS.
let package = Package(
    name: "MatrixWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MatrixWidget"),
        .testTarget(name: "MatrixWidgetTests", dependencies: ["MatrixWidget"])
    ]
)
