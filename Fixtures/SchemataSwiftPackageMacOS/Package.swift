// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture for schemata mode: an ordinary, MutantKit-unaware
// SwiftPM package with a mix of bool-literal/ternary candidates (embeddable
// by BoolLiteralSchemataLowerer/TernaryBranchSwapSchemataLowerer) and an
// arithmetic-operator candidate (experimental-profile-only, no lowerer
// registered for it, so it must fall back to isolated mode) — the
// combination `SchemataRunOrchestrationAcceptanceTests` needs to prove one
// merged report covers both kinds of results correctly.
let package = Package(
    name: "SchemataMixed",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SchemataMixed"),
        .testTarget(name: "SchemataMixedTests", dependencies: ["SchemataMixed"]),
    ]
)
