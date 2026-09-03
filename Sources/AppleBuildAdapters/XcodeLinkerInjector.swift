import Foundation

/// Turns a resolved `MutantKitSchemataRuntime` archive into the extra
/// `xcodebuild` build-setting-override arguments that link it in — the
/// Xcode analogue of `SwiftPMLinkerInjector`. `$(inherited)` is
/// load-bearing: a bare override replaces whatever the project's own
/// target already set (see `SchemataXcodeRuntimeAcceptanceTests`, which
/// proves `$(inherited)` is what keeps a project's own pre-existing
/// `OTHER_LDFLAGS` linked alongside the injected one). Pure and side-effect-
/// free, matching `SwiftPMLinkerInjector`.
///
/// Takes the exact archive *file* `SchemataRuntimeLibraryLocator` resolved
/// and validated (`Located.archivePath`) directly in `OTHER_LDFLAGS`,
/// rather than a `LIBRARY_SEARCH_PATHS` directory plus a `-l<name>`
/// convention — see `SwiftPMLinkerInjector`'s own doc comment for why a
/// name-based lookup cannot structurally guarantee it links the same bytes
/// the locator just verified.
public enum XcodeLinkerInjector {
    public static func extraArguments(archivePath: URL) -> [String] {
        ["OTHER_LDFLAGS=$(inherited) \(archivePath.path)"]
    }
}
