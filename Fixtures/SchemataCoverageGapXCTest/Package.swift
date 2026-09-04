// swift-tools-version:6.0
import PackageDescription

// Schemata coverage-gap fixture: SwiftPM macOS + XCTest, with exactly one
// bool-literal-inversion candidate a test actually covers (`coveredFlag`)
// and one it genuinely never reaches (`neverCalledFlag`) — unlike
// `Fixtures/SchemataMatrixXCTest`, which is 100% covered by design and
// cannot exercise a coverage-based fast path at all.
//
// Exists for `ExecutionProfileCoverageParityAcceptanceTests`, which proves
// `reference` and `optimized` reach the identical verdict for the uncovered
// candidate (a real, built-and-tested `.survived` — not a `.noCoverage`
// classification manufactured from a coverage map neither profile measures
// by default) unless a project has deliberately opted into
// `execution.profileCoverageSkip`. An adversarial review used this exact
// two-function shape to reproduce the finding that motivated that opt-in.
let package = Package(
    name: "CoverageGapWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CoverageGapWidget"),
        .testTarget(name: "CoverageGapWidgetTests", dependencies: ["CoverageGapWidget"])
    ]
)
