// swift-tools-version:6.0
//
// The `mutantkit` package: the CLI, its libraries, and the test target.
import PackageDescription

let package = Package(
    name: "MutantKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mutantkit", targets: ["CLI"]),
        // Exposed so Fuzz/Package.swift (a separate SwiftPM package -- see
        // its own header comment for why) can depend on it by path without
        // a plain `swift build`/`swift build --build-tests` here pulling
        // libFuzzer's own executable (and its `main()`-less driver target)
        // into this package's normal build graph.
        .library(name: "MuterCompatibility", targets: ["MuterCompatibility"]),
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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
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
        .target(name: "AppleBuildAdapters", dependencies: ["MutationExecution", "SwiftCoreOperators", "MutationPlanner"]),

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

        // Classifies which mutations of a plan a schemata run can embed: it runs
        // SchemataChunkPlanner.plan (the same target-resolution/registry
        // machinery a real run uses) to determine authoritative embedded
        // membership, not just a lowerer's own `analyze()`. See
        // Sources/SchemataEligibilityClassifier/EligibilityClassification.swift's
        // doc comment. `MutantKitTests` `@testable import`s it.
        .executableTarget(
            name: "SchemataEligibilityClassifier",
            dependencies: [
                "MutationModel", "SwiftFrontend", "SwiftCoreOperators", "MutationPlanner", "AppleBuildAdapters",
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
                "CLI", "SchemataEligibilityClassifier",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
