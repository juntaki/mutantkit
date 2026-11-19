// swift-tools-version:6.2
import PackageDescription

// A library target whose code is main-actor isolated by default
// (`.defaultIsolation(MainActor.self)`, Swift 6.2+). The schemata preamble is
// prepended into this target's own sources, so it takes the same default
// isolation as the code it is mutating — this fixture proves its runtime
// declarations stay callable from the generated descriptor initializer and
// from a mutated `nonisolated` function, and that every chunk builds and runs
// in schemata mode rather than falling back to isolated mode.
let package = Package(
    name: "MainActorDefaultPackage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MainActorGate",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MainActorGateTests", dependencies: ["MainActorGate"])
    ]
)
