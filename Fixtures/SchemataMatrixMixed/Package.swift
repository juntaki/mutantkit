// swift-tools-version:6.0
import PackageDescription

// Schemata supported-matrix fixture: SwiftPM macOS with ONE test target
// containing both an XCTestCase class and a Swift Testing @Suite —
// deliberately mixed, not two separate test targets, since the question
// this fixture answers is whether schemata mode's own test-result parsing
// (a single .xctest bundle report) handles both frameworks' results
// correctly when they coexist in the same bundle. See
// Fixtures/SchemataMatrixXCTest/Package.swift's own comment for why this
// fixture is fully covered rather than deliberately partial.
let package = Package(
    name: "MatrixWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MatrixWidget"),
        .testTarget(name: "MatrixWidgetTests", dependencies: ["MatrixWidget"])
    ]
)
