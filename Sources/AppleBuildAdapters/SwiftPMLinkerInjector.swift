import Foundation

/// Turns a resolved `MutantKitSchemataRuntime` archive into the extra
/// `swift build`/`swift test` command-line arguments that link it in — the
/// SwiftPM analogue of the Xcode path's `OTHER_LDFLAGS` build-setting
/// override (`SchemataXcodeRuntimeAcceptanceTests`): no `Package.swift`
/// edit, no dependency graph entry, just linker flags appended to the
/// invocation. Pure and side-effect-free — no process spawning, no
/// filesystem access — so it is unit-testable on its own;
/// `SchemataRuntimeLibraryLocator` is the piece that actually finds the
/// archive this takes as input.
///
/// Takes the exact archive *file* `SchemataRuntimeLibraryLocator` resolved
/// and validated (`Located.archivePath`), not a directory plus a `-l<name>`
/// convention: a `-L<dir> -lMutantKitSchemataRuntime` pair only links
/// whatever file matching that fixed name happens to sit in `<dir>` at
/// link time, which is not necessarily the exact bytes the locator's own
/// SHA-256 check just verified — a bundled manifest could in principle
/// name its verified archive something other than
/// `libMutantKitSchemataRuntime.a` while a *different* file with that
/// conventional name also sits alongside it. Passing the file path
/// directly closes that gap structurally: the bytes verified and the
/// bytes linked are provably the same file, not merely two lookups that
/// usually agree.
public enum SwiftPMLinkerInjector {
    public static func extraArguments(archivePath: URL) -> [String] {
        ["-Xlinker", archivePath.path]
    }
}
