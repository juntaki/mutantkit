import Foundation

/// Where the *running* `mutantkit` executable actually lives on disk —
/// `SchemataRuntimeLibraryLocator`'s anchor for finding a bundled
/// `lib/mutantkit/schemata/` alongside it, without depending on the
/// current working directory or on `CommandLine.arguments[0]` directly
/// (which can be a bare relative name resolved via `$PATH`, never itself an
/// absolute, symlink-resolved path).
///
/// `Bundle.main.executablePath` is the mechanism: `ExecutionImplementationVersion`'s
/// own prior investigation (see its doc comment) confirmed by direct
/// experiment that it resolves correctly across every real invocation shape
/// — a direct path, a relative path, a symlink, and a `$PATH` lookup — for
/// this exact SwiftPM executable target. That investigation used it only to
/// evaluate (and ultimately reject, for unrelated reasons) a whole-binary
/// content hash; this type is the first production use of the resolution
/// mechanism itself.
/// No injectable seam of its own: the one thing worth substituting for a
/// test — "what does a bundled-runtime lookup do given a controlled
/// install location" — is already covered by `SchemataRuntimeLibraryLocator
/// .locate`'s own `executableURL:` parameter, which bypasses this type
/// entirely. Adding a second knob here (e.g. an injectable `Bundle`) would
/// only add an untested, unused path: nothing meaningfully fakes
/// `Bundle.executablePath`'s own resolution for a plain directory that is
/// not a real `.app`/`.framework` bundle.
public enum MutantKitInstallLocation {
    /// `nil` only in the rare case `Bundle.main.executablePath` itself
    /// cannot determine the running executable's path at all — callers
    /// treat that the same as "no bundled runtime found", never a crash.
    /// Symlinks are resolved (`.resolvingSymlinksInPath()`) so a `$PATH`
    /// shim/symlink install (e.g. Homebrew's `bin/mutantkit ->
    /// ../Cellar/mutantkit/<version>/bin/mutantkit`) still anchors on the
    /// real install directory containing `lib/mutantkit/schemata`, not the
    /// symlink's own parent.
    public static func executableURL() -> URL? {
        guard let path = Bundle.main.executablePath else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}
