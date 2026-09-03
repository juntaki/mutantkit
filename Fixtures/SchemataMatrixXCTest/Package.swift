// swift-tools-version:6.0
import PackageDescription

// Schemata supported-matrix fixture: SwiftPM macOS + XCTest, with exactly one
// candidate per default-enabled, schemata-eligible operator
// (bool-literal-inversion, relational-operator-replacement,
// logical-connector-replacement, unary-not-removal, return-value-replacement,
// ternary-branch-swap), and every single one of those candidates fully
// covered by a dedicated test. Unlike Fixtures/SchemataSwiftPackageMacOS
// (which deliberately leaves some candidates uncovered to prove the
// mixed-fallback reporting path), this fixture exists to prove the opposite:
// a genuinely fully-covered project produces zero isolated fallback of any
// kind under schemata mode, not merely a correct-but-partial-fallback run.
let package = Package(
    name: "MatrixWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MatrixWidget"),
        .testTarget(name: "MatrixWidgetTests", dependencies: ["MatrixWidget"])
    ]
)
