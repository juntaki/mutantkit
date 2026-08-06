import Foundation

/// Turns a resolved `MutantKitSchemataRuntime` library directory into the
/// extra `swift build`/`swift test` command-line arguments that link it in
/// — the SwiftPM analogue of the Xcode path's `OTHER_LDFLAGS`/
/// `LIBRARY_SEARCH_PATHS` build-setting overrides
/// (`SchemataXcodeRuntimeAcceptanceTests`): no `Package.swift` edit, no
/// dependency graph entry, just linker flags appended to the invocation.
/// Pure and side-effect-free — no process spawning, no filesystem access —
/// so it is unit-testable on its own; `SchemataRuntimeLibraryLocator` is the
/// piece that actually finds the directory this takes as input.
public enum SwiftPMLinkerInjector {
    public static func extraArguments(libraryDirectory: URL) -> [String] {
        ["-Xlinker", "-L\(libraryDirectory.path)", "-Xlinker", "-lMutantKitSchemataRuntime"]
    }
}
