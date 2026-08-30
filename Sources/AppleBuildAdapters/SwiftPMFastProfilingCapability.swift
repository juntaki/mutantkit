import Foundation
import MutationExecution

/// Whether the fast per-test coverage path can be trusted for this run.
///
/// Never "use it if it looks like it'll work" — every check that decides
/// `.supported` is a real, verified precondition, not a guess. `.unsupported`
/// is always safe: the caller falls back to the serial reference profiler,
/// which is correct for every project this fast path does not yet cover.
///
/// Deliberately conservative: Swift Testing only, exactly one unambiguous
/// `.xctest` product, every discovered test attributable to it. A package
/// with even one XCTest-shaped test among its discovered tests is
/// `.unsupported` in full — there is no fast XCTest backend (empirical
/// testing found `xcodebuild`'s own coverage collection cannot be batched
/// per test, and this adapter is SwiftPM-only regardless), so a mixed
/// package never gets a partial speedup, only the correct, complete serial
/// map.
enum SwiftPMFastProfilingCapability: Sendable, Equatable {
    case supported(testBundleBinary: URL)
    case unsupported(reason: String)

    /// - Parameter tests: every test this run needs attribution for
    ///   (already scoped to configured targets — the same list the serial
    ///   path enumerates from).
    static func check(tests: [TestIdentifier], productsDirectory: URL) -> SwiftPMFastProfilingCapability {
        guard !diagnosticallyDisabled else {
            return .unsupported(reason: "disabled via MUTANTKIT_DISABLE_FAST_PROFILING")
        }
        guard !tests.isEmpty else {
            return .unsupported(reason: "no tests discovered")
        }
        guard tests.allSatisfy(\.isSwiftTestingShaped) else {
            return .unsupported(reason: "at least one discovered test is XCTest-shaped; the fast path only supports Swift Testing")
        }
        guard let testBundleBinary = SwiftPMTestProductResolver.resolve(productsDirectory: productsDirectory) else {
            return .unsupported(reason: "could not resolve exactly one .xctest bundle's binary")
        }
        return .supported(testBundleBinary: testBundleBinary)
    }

    /// Internal-only diagnostic escape hatch, not a public config surface:
    /// forces `.unsupported` regardless of what the real checks would say,
    /// for isolating whether a regression is this fast path's own doing.
    static var diagnosticallyDisabled: Bool {
        ProcessInfo.processInfo.environment["MUTANTKIT_DISABLE_FAST_PROFILING"] == "1"
    }
}
