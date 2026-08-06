// swift-tools-version:6.0
import PackageDescription

// Acceptance fixture: a Swift package that declares ONLY iOS.
//
// This is the shape that must never be built with `swift test`. The host
// toolchain would try to compile it for macOS, UIKit would not resolve, and the
// failure surfaces as a confusing compile error rather than "you pointed the
// wrong build system at this package". ProjectDetector must classify this as
// `.swiftPackageApple` from the manifest's `platforms` and route it to
// xcodebuild with an iOS destination.
//
// The UIKit import below is load-bearing: it is what makes a wrong-adapter
// decision fail loudly instead of passing by accident.
let package = Package(
    name: "Formatting",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Formatting", targets: ["Formatting"])],
    targets: [
        .target(name: "Formatting"),
        .testTarget(name: "FormattingTests", dependencies: ["Formatting"]),
    ]
)
