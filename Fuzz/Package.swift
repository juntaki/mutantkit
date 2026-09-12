// swift-tools-version:6.0
//
// A separate SwiftPM package, not a target inside the root package, so
// that a plain `swift build`/`swift build --build-tests` at the repo root
// (every ordinary CI job) never touches `muter-config-fuzzer`. It once
// lived as two targets there; `MuterConfigFuzzerDriver`'s `main()` is
// supplied by libFuzzer's own runtime only when linked with
// `-Xlinker <libclang_rt.fuzzer_osx.a>` (see `.github/workflows/fuzz.yml`)
// -- without that link flag the same target fails with "Undefined symbols
// ... _main", which broke the ordinary build graph for every job in this
// repo the day it was added there instead of here.
import Foundation
import PackageDescription

/// SwiftPM identifies a local path dependency by its checkout directory's
/// own basename, not the target manifest's `name:` field -- computed the
/// same way here so `.product(package:)` below stays correct no matter
/// what the enclosing checkout is named.
let parentPackageIdentity = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Fuzz/
    .deletingLastPathComponent() // repository root
    .lastPathComponent

let package = Package(
    name: "mutantkit-fuzz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "muter-config-fuzzer", targets: ["MuterConfigFuzzer"])
    ],
    dependencies: [
        // SwiftPM derives a local path dependency's identity from the
        // checkout directory's own name, not this manifest's `name:` field
        // ("MutantKit") -- verified locally where the checkout directory
        // happened to share this Fuzz package's own name, which produced a
        // confusing "unknown package" error pointing at the wrong culprit.
        // `parentPackageIdentity` below computes the real identity the same
        // way SwiftPM does, so this manifest works regardless of what the
        // enclosing checkout is named on any given machine or CI runner.
        .package(path: "..")
    ],
    targets: [
        // A library target so SwiftPM does not synthesize an executable
        // `main`; libFuzzer supplies that entry point through the tiny C
        // executable target below.
        .target(
            name: "MuterConfigFuzzHarness",
            dependencies: [.product(name: "MuterCompatibility", package: parentPackageIdentity)],
            path: "Sources/MuterConfigFuzzHarness"
        ),
        .executableTarget(
            name: "MuterConfigFuzzer",
            dependencies: ["MuterConfigFuzzHarness"],
            path: "Sources/MuterConfigFuzzerDriver"
        )
    ]
)
