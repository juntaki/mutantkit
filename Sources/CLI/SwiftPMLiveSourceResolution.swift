import AppleBuildAdapters
import Foundation
import MutationModel
import MutationPlanner

/// Resolves `sources.include`/`exclude` for a SwiftPM project against
/// SwiftPM's own real, live build graph at `plan` time — instead of asking
/// `mutantkit.yml` to hold a static, separately-maintained list of "what
/// files exist" that inevitably drifts from `Package.swift`'s own answer to
/// that question.
///
/// Root-caused 2026-09-17 against a real project: a target's `sources:`
/// allow-list narrower than its own directory made a directory-level
/// `sources.include` over-include a file no target actually compiled — 28
/// of 50 budgeted mutants then failed `buildProductIdenticalToBaseline`.
/// The first fix tried was writing an exact file list into `mutantkit.yml`
/// instead; that traded the over-inclusion bug for its mirror — a file
/// added to the same directory after `setup` last ran was silently no
/// longer covered. Both are the same underlying mistake: a config file
/// duplicating a fact the build system already knows, and drifting from it.
///
/// The fix that does not drift is not keeping a better snapshot, it is not
/// keeping a snapshot at all — modeled on how Stryker.NET treats an MSBuild
/// project's own `Compile` item list as authoritative rather than asking a
/// separate config file to duplicate it. `sources.include`/`exclude`, for a
/// SwiftPM project, are demoted from "the list of files that exist" to an
/// *optional additional filter* layered over SwiftPM's own live-resolved
/// compiled set: `["**"]` (what `init`/`setup` write by default) applies no
/// narrowing at all; a real pattern narrows further, exactly as before —
/// just intersected with reality on every run, rather than assumed to be
/// reality.
enum SwiftPMLiveSourceResolution {
    /// `nil` means "could not resolve, or not applicable" — the caller
    /// should keep the configuration's own `sources` unchanged. Safe for
    /// every project kind this cannot apply to (a directory/file glob is a
    /// complete, self-sufficient answer to "what exists" on its own), and
    /// for a SwiftPM project whose `sources.include` is itself a real,
    /// hand-written glob — that degrades to exactly the pre-existing,
    /// config-file-is-authoritative behavior this whole area had before
    /// this type existed, matching every other SwiftPM-detection call
    /// site's established "detection can legitimately fail; never block on
    /// it" philosophy.
    ///
    /// **Not** safe, and therefore never returned, when `sources.include`
    /// is exactly `["**"]` — `init`/`setup`'s own "no additional narrowing"
    /// marker for a resolved SwiftPM detection (`ProjectDetectionPlan
    /// .detectedSwiftPMTestTargetsAndSources`'s own doc comment). That
    /// marker is meaningful only intersected with a real, live-resolved
    /// compiled set; read on its own by `SourceFileWalker` it means "every
    /// `.swift` file in the whole project, not just this target's" —
    /// caught by `codex review`: a transient `swift package describe`
    /// failure (or any other early-exit below) would otherwise silently
    /// expand a normal, narrow SwiftPM run into a whole-repository one.
    /// Every early exit in this function therefore routes through
    /// `giveUp()`, an explicit, empty-but-safe scope in that one case
    /// instead of `nil`.
    static func resolve(configuration: Configuration, root: URL) async -> SourceSettings? {
        func giveUp() -> SourceSettings? {
            configuration.sources.include == ["**"] ? SourceSettings(include: [], exclude: []) : nil
        }

        let effectiveKind = await Self.effectiveProjectKind(configuration: configuration, root: root)
        guard effectiveKind == .swiftPackageMacOS || effectiveKind == .swiftPackageApple else { return giveUp() }
        guard !configuration.tests.targets.isEmpty else { return giveUp() }

        // `project.path`: the same "package lives elsewhere" support every
        // other adapter honors (`SwiftPackageMacOSAdapter.diagnose`,
        // `Diagnostics.swiftVersion`), relative *or* absolute. `swift
        // package describe` has to run *there*, not at `root` — and the
        // file paths it reports back are relative to that location, not to
        // `root`, so they need the same prefix restored before they can be
        // compared against `SourceFileWalker`'s (always `root`-relative)
        // output or matched against the config's own `sources.include`/
        // `exclude` patterns, which are themselves always written relative
        // to `root`. A package that does not live under `root` at all (a
        // real if unusual `project.path`, e.g. a workspace referencing a
        // sibling checkout) has no such prefix to express — resolving
        // against it would silently score this run against an unrelated
        // package, so that case bails out too.
        guard case let .resolvable(packageRoot, relativePackagePath) = Self.packageLocation(
            path: configuration.project.path, root: root
        ) else { return giveUp() }

        guard let graph = try? await SwiftPMTargetResolver.resolveDependencyGraph(projectRoot: packageRoot) else {
            return giveUp()
        }

        let compiledAtPackageRoot = graph.sourceFiles(reachableFrom: configuration.tests.targets)
        Self.warnIfNoConfiguredTestTargetResolved(configured: configuration.tests.targets, graph: graph)
        let compiled = relativePackagePath.map { prefix in
            compiledAtPackageRoot.map { "\(prefix)/\($0)" }
        } ?? compiledAtPackageRoot

        let narrowed = Self.narrow(compiled, include: configuration.sources.include, exclude: configuration.sources.exclude)
        // `exclude: []`: already applied above, and the returned `include`
        // is exact files from here on — nothing left for a second exclude
        // pass to remove.
        //
        // Deliberately still returns an override here even when `narrowed`
        // ends up empty (every configured `tests.targets` name absent from
        // the graph, most commonly) rather than `nil`: falling back to
        // `configuration.sources` unchanged would mean falling back to
        // `["**"]` — `init`/`setup`'s own "no additional narrowing" marker,
        // meaningful only paired with live resolution — which `SourceFileWalker`
        // would then read as "every `.swift` file in the whole project",
        // silently mutating far more than intended instead of the empty,
        // loudly-warned-about scope this produces via `warnIfNothingDiscovered`.
        return SourceSettings(include: narrowed, exclude: [])
    }

    /// `configuration.project.kind == .auto` (the documented default — see
    /// `docs/configuration.md`'s own reference config) is a real, common,
    /// intentional choice, not only a "detection failed" leftover: a
    /// project can rely on `AppleAdapterFactory`'s own runtime detection
    /// and never pin a concrete kind in `mutantkit.yml` at all. Skipping
    /// live resolution for `.auto` would silently exempt every project that
    /// makes that choice from the whole fix this type exists for, so this
    /// re-runs the same real detection `init`/`setup` already uses
    /// (`ProjectDetector.detect`) to find the effective kind before
    /// deciding whether SwiftPM's build graph applies — never mutates
    /// `configuration` itself, which keeps `project.kind: auto` exactly as
    /// the user wrote it.
    private static func effectiveProjectKind(configuration: Configuration, root: URL) async -> ProjectKind? {
        guard configuration.project.kind != .auto else {
            return try? await ProjectDetector.detect(in: root).kind
        }
        return configuration.project.kind
    }

    /// A configured `tests.targets` name absent from SwiftPM's own resolved
    /// graph (a typo, a renamed or removed test target) degrades `plan` to
    /// an empty, loudly-`warnIfNothingDiscovered`-flagged scope rather than
    /// silently falling back to a potentially far-too-broad `sources.include`
    /// (see `resolve`'s own comment on why). That existing warning's own
    /// wording ("sources.include/exclude does not match…") is misleading
    /// for this specific cause, so this adds a second, targeted one naming
    /// the actual missing target(s) — printed here, not returned, since
    /// `resolve` has exactly one real caller and nothing downstream needs
    /// to act on this beyond surfacing it.
    private static func warnIfNoConfiguredTestTargetResolved(configured: [String], graph: SwiftPMDependencyGraph) {
        let resolvedNames = Set(graph.targets.keys)
        let missing = configured.filter { !resolvedNames.contains($0) }
        guard !missing.isEmpty else { return }
        FileHandle.standardError.write(Data("""
        warning: tests.targets name(s) not found in this SwiftPM project's build graph: \
        \(missing.joined(separator: ", ")). Check for a typo, or a renamed/removed test \
        target — `mutantkit setup` re-detects this automatically.\n\n
        """.utf8))
    }

    /// Where `swift package describe` should actually run, given
    /// `project.path` — and, when that differs from `root`, the prefix
    /// needed to rebase its (package-relative) file paths back onto
    /// `root`-relative ones.
    enum PackageLocation: Equatable {
        /// The package is `root` itself, or `root` plus a real subdirectory
        /// prefix (`path` given relative, or absolute but still under
        /// `root`) — `prefix == nil` for the former, set for the latter.
        case resolvable(packageRoot: URL, prefix: String?)
        /// `path` names somewhere `root` does not contain at all (an
        /// absolute path outside it, most plausibly) — there is no
        /// `root`-relative prefix to express what SwiftPM would report, so
        /// resolving there could only silently score this run against an
        /// unrelated package.
        case outsideRoot
    }

    /// Pure and filesystem-free (deliberately `standardizedFileURL` only,
    /// not `resolvingSymlinksInPath` — this project.path edge case does not
    /// need to survive a symlinked `root`, and skipping it keeps this
    /// testable without a real filesystem) — the string-prefix logic that
    /// decides whether `resolve` can proceed, and how to rebase what it
    /// finds.
    static func packageLocation(path: String?, root: URL) -> PackageLocation {
        guard let path, !path.isEmpty, path != "." else {
            return .resolvable(packageRoot: root, prefix: nil)
        }
        let packageRoot = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let rootPath = root.standardizedFileURL.path
        let packageRootPath = packageRoot.standardizedFileURL.path

        if packageRootPath == rootPath {
            return .resolvable(packageRoot: packageRoot, prefix: nil)
        }
        guard packageRootPath.hasPrefix(rootPath + "/") else { return .outsideRoot }
        return .resolvable(packageRoot: packageRoot, prefix: String(packageRootPath.dropFirst(rootPath.count + 1)))
    }

    /// The pure filter, factored out so it is testable without a real
    /// filesystem or `swift package describe` call: SwiftPM's own compiled
    /// set, narrowed by whatever `sources.include`/`exclude` the config file
    /// adds on top — this can only ever narrow that set, never widen it
    /// beyond what SwiftPM actually compiles.
    static func narrow(_ compiled: [String], include: [String], exclude: [String]) -> [String] {
        compiled
            .filter { Glob.matchesAny(patterns: include, path: $0) }
            .filter { !Glob.matchesAny(patterns: exclude, path: $0) }
            .sorted()
    }
}
