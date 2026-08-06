import Foundation

/// Turns a resolved `MutantKitSchemataRuntime` library directory into the
/// extra `xcodebuild` build-setting-override arguments that link it in — the
/// Xcode analogue of `SwiftPMLinkerInjector`. `$(inherited)` on both settings
/// is load-bearing: a bare override replaces whatever the project's own
/// target already set (see `SchemataXcodeRuntimeAcceptanceTests`, which
/// proves `$(inherited)` is what keeps a project's own pre-existing
/// `OTHER_LDFLAGS` linked alongside the injected one). Pure and side-effect-
/// free, matching `SwiftPMLinkerInjector`.
public enum XcodeLinkerInjector {
    public static func extraArguments(libraryDirectory: URL) -> [String] {
        [
            "OTHER_LDFLAGS=$(inherited) -lMutantKitSchemataRuntime",
            "LIBRARY_SEARCH_PATHS=$(inherited) \(libraryDirectory.path)"
        ]
    }
}
