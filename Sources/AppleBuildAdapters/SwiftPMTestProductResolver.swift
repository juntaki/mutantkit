import Foundation

/// Resolves the one thing `SwiftPMDirectCoverageRunner` needs before it can
/// invoke `swiftpm-testing-helper` directly: the actual Mach-O binary inside
/// a SwiftPM package's built `.xctest` bundle.
///
/// Deliberately narrow. This does not decide *whether* to use the fast path
/// (that is `SwiftPMFastProfilingCapability`'s job, added alongside the
/// backend that consumes this) — it only answers "does a bundle exist here,
/// and is it unambiguous", the same all-or-nothing discipline as everything
/// else in this fast-profiler substrate: an ambiguous or missing product is
/// `nil`, never a guess at which one the caller probably meant.
enum SwiftPMTestProductResolver {
    /// - Parameter productsDirectory: `SwiftPackageMacOSAdapter
    ///   .productsDirectory(in:)`'s own `.build/debug` — this resolver does
    ///   not re-derive that path itself, so it stays testable against a
    ///   hand-built directory tree with no real `swift build` involved.
    /// - Returns: `nil` when zero or more than one top-level `.xctest`
    ///   bundle exists in `productsDirectory`, or when the resolved bundle's
    ///   own Mach-O binary is missing. "Multiple bundles, pick the first" is
    ///   explicitly disallowed — an ambiguous product resolution is exactly
    ///   the kind of guess this fast path exists to never make, since a
    ///   silently-wrong bundle would make every test in it measure the
    ///   wrong product's coverage.
    static func resolve(productsDirectory: URL, fileManager: FileManager = .default) -> URL? {
        // `SwiftPackageMacOSAdapter.productsDirectory(in:)` is `.build/debug`
        // -- SwiftPM's own *relative* symlink to `.build/<triple>/debug`.
        // Confirmed empirically: `FileManager.contentsOfDirectory(at:)`
        // fails closed with a POSIX ENOTDIR ("Not a directory") on that
        // exact symlink, regardless of any `isDirectory` hint on the URL --
        // `ls`/`opendir` follow it fine, but this Foundation API does not
        // unless the symlink is resolved first.
        let resolvedDirectory = productsDirectory.resolvingSymlinksInPath()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: resolvedDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        let bundles = entries.filter { $0.pathExtension == "xctest" }
        guard bundles.count == 1, let bundle = bundles.first else { return nil }

        let binaryName = bundle.deletingPathExtension().lastPathComponent
        let binaryPath = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(binaryName, isDirectory: false)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: binaryPath.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return binaryPath
    }
}
