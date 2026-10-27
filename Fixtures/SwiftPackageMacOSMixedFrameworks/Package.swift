// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture: one test target holding both an XCTest case and Swift
// Testing tests, to pin where `swift test --xunit-output` records each
// framework's failures. The tests read FIXTURE_* environment variables so the
// acceptance suite can make one of them fail, or end the test process, without
// a mutation.
let package = Package(
    name: "Gate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Gate"),
        .testTarget(name: "GateTests", dependencies: ["Gate"]),
    ]
)
