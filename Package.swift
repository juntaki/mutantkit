// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MutantKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mutantkit", targets: ["CLI"]),
        .library(name: "MutationModel", targets: ["MutationModel"]),
        .library(name: "SwiftFrontend", targets: ["SwiftFrontend"]),
        .library(name: "SwiftCoreOperators", targets: ["SwiftCoreOperators"]),
        .library(name: "ApplePlatformOperators", targets: ["ApplePlatformOperators"]),
        // `.static`, explicitly: an `xcodebuild`-driven target (see
        // `SchemataXcodeRuntimeAcceptanceTests`) links this via a plain
        // `-L<path> -lMutantKitSchemataRuntime` build-setting override, not
        // through SwiftPM's own dependency graph — that needs one discrete
        // `.a` file (`libMutantKitSchemataRuntime.a`, named after this
        // *product*, not the `MutantKitSchemataRuntimeC` target it wraps)
        // at a known, stable name, not whatever an "automatic" product
        // would produce.
        .library(name: "MutantKitSchemataRuntime", type: .static, targets: ["MutantKitSchemataRuntimeC"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0")
    ],
    targets: [
        // MARK: Core

        .target(name: "MutationModel"),

        .target(
            name: "SwiftFrontend",
            dependencies: [
                "MutationModel",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax")
            ]
        ),

        // MARK: Operators

        .target(name: "SwiftCoreOperators", dependencies: ["SwiftFrontend"]),
        .target(name: "ApplePlatformOperators", dependencies: ["SwiftFrontend"]),

        .target(
            name: "MutationPlanner",
            dependencies: ["SwiftFrontend", "SwiftCoreOperators", "ApplePlatformOperators"]
        ),

        // MARK: Schemata runtime

        // Linked into a mutated build under test, never into MutantKit
        // itself — the target-under-test's process calls
        // `__mutantkitIsActive`, MutantKit's own process never does. A
        // plain C target (not Swift) so it imports into any Swift module
        // with no ABI-stability requirements of its own, and so it can be
        // built once and reused verbatim regardless of which Swift version
        // the target under test compiles with.
        .target(name: "MutantKitSchemataRuntimeC"),

        // MARK: Execution

        // Deliberately does *not* depend on `MutantKitSchemataRuntimeC`:
        // the host collector only reads the plain-text evidence file the
        // runtime writes (see `SchemataEvidenceCollector`), never calls
        // into the C library itself — that library is linked into the
        // target *under test*, a different process entirely.
        .target(name: "MutationExecution", dependencies: ["MutationModel", "SwiftFrontend"]),
        .target(name: "AppleBuildAdapters", dependencies: ["MutationExecution", "SwiftCoreOperators"]),

        // MARK: Output

        .target(name: "Reporting", dependencies: ["MutationModel"]),
        .target(
            name: "MuterCompatibility",
            dependencies: ["MutationModel", .product(name: "Yams", package: "Yams")]
        ),

        .executableTarget(
            name: "CLI",
            dependencies: [
                "MutationModel", "MutationPlanner", "MutationExecution",
                "AppleBuildAdapters", "Reporting", "MuterCompatibility",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ]
        ),

        // MARK: MutantBench-Swift

        // Deliberately depends on nothing else in this package —
        // `MutationModel`/`MutationExecution` included. Both MutantKit and
        // Muter are external processes to this target, never in-process
        // engines; coupling to MutantKit's own execution engine would give
        // it an unfair, Muter-can-never-have shortcut in the very benchmark
        // meant to compare them fairly. See `Benchmarks/README.md`.
        .executableTarget(
            name: "BenchmarkRunner",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "BenchmarkRunnerTests", dependencies: ["BenchmarkRunner"]),

        // MARK: Budget Selection v2 evaluation (task #25/#26, Research/budget-selection-v2)

        // Post-processes plan.json/report.json produced by the real
        // `mutantkit plan`/`run` CLI (which does all discovery/execution) —
        // this target only needs in-process access to `BudgetSelectorV2`
        // for the proxy-dependence screen's synthetic weight-vector
        // resampling, which must run thousands of times fast and cannot
        // reasonably shell out per round.
        .executableTarget(
            name: "BudgetV2Eval",
            dependencies: [
                "MutationModel", "MutationPlanner",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),

        // MARK: Tests

        .testTarget(
            name: "MutantKitTests",
            dependencies: [
                "MutationModel", "SwiftFrontend", "SwiftCoreOperators",
                "ApplePlatformOperators", "MutationPlanner", "MutationExecution",
                "AppleBuildAdapters", "Reporting", "MuterCompatibility",
                "CLI",
                // Not imported by any test file — a target dependency here
                // exists only so `swift build --build-tests` (already run
                // before every test invocation) also produces
                // `libMutantKitSchemataRuntime.a`. `SchemataXcodeRuntimeAcceptanceTests`
                // needs that file to already exist, the same way
                // `AcceptanceSupport.binary()` needs the `mutantkit`
                // executable to already exist — neither acceptance suite
                // shells out to `swift build` itself, which from inside an
                // already-running `swift test` would deadlock on this
                // package's own build lock.
                "MutantKitSchemataRuntimeC"
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
