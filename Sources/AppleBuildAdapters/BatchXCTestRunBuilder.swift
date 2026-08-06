import Foundation
import MutationExecution

/// One mutant's slot in a batched `.xctestrun`.
public struct BatchTestItem: Sendable {
    /// Both the `TestConfigurations` entry's `Name` and the key batch
    /// results are reported back under — the same string a mutant's own
    /// `-only-testing:` invocation would have used to label its result
    /// bundle, so evidence stays traceable back to the mutant it came from.
    public let configurationName: String
    /// The v1 `.xctestrun` this mutant's own `build-for-testing` already
    /// produced — read for its `TestTargets` dict, never executed on its
    /// own. Each mutant keeps its own build, its own binary, its own
    /// activation hash; batching only changes how many `xcodebuild`
    /// processes it takes to test all of them, never what gets built.
    public let xctestrunPath: URL
    /// Narrows this configuration to only these tests, when known — the
    /// same selection `TestSelecting` already computes. `nil` runs every
    /// target's full configured list, the same safe fallback used
    /// everywhere else a selection can be unknown.
    ///
    /// Each identifier keeps its owning target (`TestIdentifier.target`)
    /// because a v1 xctestrun can fold in more than one test target — most
    /// commonly a unit test bundle alongside a UI test bundle for the same
    /// scheme — and a selection computed from unit-test coverage names only
    /// the unit bundle's own tests. `build(items:)` uses the target to
    /// decide, per bundle, whether to narrow it or drop it outright; see
    /// that method's doc comment for why dropping (not narrowing to an
    /// empty match) is required for a bundle with none of its own tests
    /// selected.
    public let onlyTestingIdentifiers: [TestIdentifier]?

    public init(configurationName: String, xctestrunPath: URL, onlyTestingIdentifiers: [TestIdentifier]?) {
        self.configurationName = configurationName
        self.xctestrunPath = xctestrunPath
        self.onlyTestingIdentifiers = onlyTestingIdentifiers
    }
}

public enum BatchXCTestRunError: Error, CustomStringConvertible {
    case unreadable(path: String, underlying: String)
    case malformed(path: String)
    case noTestTargets(path: String)
    case selectionMatchesNoTarget(path: String, configurationName: String)

    public var description: String {
        switch self {
        case let .unreadable(path, underlying):
            "Could not read \(path): \(underlying)"
        case let .malformed(path):
            "\(path) does not parse as an .xctestrun property list."
        case let .noTestTargets(path):
            "\(path) names no test target to fold into the batch."
        case let .selectionMatchesNoTarget(path, configurationName):
            """
            None of \(configurationName)'s selected tests belong to any test target in \(path) — \
            every target would have been dropped, leaving this configuration with nothing to run.
            """
        }
    }
}

/// Merges several mutants' own, already-built `.xctestrun` files into one
/// `.xctestrun` v2 batch file — one `TestConfigurations` entry per mutant —
/// so `xcodebuild test-without-building` tests all of them in a single
/// process instead of one per invocation.
///
/// Confirmed empirically, not assumed: `xcodebuild` pays a fixed cost once
/// per invocation (simulator install/launch, on the order of tens of
/// seconds) and only a small fraction of that — about a second — for each
/// additional configuration in the same batch, and recovers on its own from
/// a configuration whose test process crashes, continuing to the next one
/// in the same batch. Every configuration's result is independently
/// attributable afterward by `configurationName` — see
/// `XCResultAdapter.classifyBatch`.
public enum BatchXCTestRunBuilder {
    /// Reads each item's own v1 `.xctestrun`, extracts its test target(s),
    /// and merges them into one v2 batch document.
    public static func build(items: [BatchTestItem]) throws -> Data {
        var parsed: [(configurationName: String, testTargets: [[String: Any]])] = []

        for item in items {
            let data: Data
            do {
                data = try Data(contentsOf: item.xctestrunPath)
            } catch {
                throw BatchXCTestRunError.unreadable(
                    path: item.xctestrunPath.path, underlying: error.localizedDescription
                )
            }

            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
            else {
                throw BatchXCTestRunError.malformed(path: item.xctestrunPath.path)
            }

            let targets = testTargets(fromV1: plist)
            guard !targets.isEmpty else {
                throw BatchXCTestRunError.noTestTargets(path: item.xctestrunPath.path)
            }

            // `__TESTROOT__` (and friends) are placeholders `xcodebuild`
            // expands relative to *where the .xctestrun file being run
            // lives* — for this mutant's own, unbatched xctestrun, that is
            // correctly its own products directory. Folded unmodified into
            // one shared batch file written somewhere else entirely, the
            // same placeholder would instead expand to the *batch* file's
            // directory, and every product path in it would point at
            // nothing. Resolved to this mutant's own absolute products
            // directory before merging, so the batch document needs no
            // placeholder of its own and every path in it is already correct
            // regardless of where the batch file itself is written.
            let testRoot = item.xctestrunPath.deletingLastPathComponent().path
            let narrowed: [[String: Any]] = targets.compactMap { entry -> [String: Any]? in
                var target = resolvingTestRootPlaceholders(in: entry.target, testRoot: testRoot)
                guard let onlyTestingIdentifiers = item.onlyTestingIdentifiers else { return target }
                // Scoped to this one bundle: an identifier from a sibling
                // target (e.g. a UI test bundle folded into the same v1
                // xctestrun as the unit test bundle a coverage-based
                // selection actually named) must never reach this bundle's
                // own `OnlyTestIdentifiers`.
                let ownIdentifiers = onlyTestingIdentifiers
                    .filter { $0.target == entry.name }
                    .map(\.qualifiedName)
                // A bundle with zero of its own tests selected is dropped
                // entirely, not kept with a filter matching nothing. Kept,
                // `xcodebuild` still launches that bundle's runner to
                // resolve the (empty) selection — for a UI test bundle,
                // confirmed by direct reproduction to reliably fail with
                // "Timed out waiting for AX loaded notification" rather
                // than cleanly reporting zero tests. Dropping the bundle is
                // also exactly what `-only-testing:<other target>/...`
                // already does for every non-batched, single-configuration
                // run — this keeps the batched path matching that same
                // target-level omission instead of only imitating its
                // per-test narrowing.
                guard !ownIdentifiers.isEmpty else { return nil }
                target["OnlyTestIdentifiers"] = ownIdentifiers
                return target
            }
            if item.onlyTestingIdentifiers != nil, narrowed.isEmpty {
                throw BatchXCTestRunError.selectionMatchesNoTarget(
                    path: item.xctestrunPath.path, configurationName: item.configurationName
                )
            }

            parsed.append((configurationName: item.configurationName, testTargets: narrowed))
        }

        let document = merge(parsed)
        return try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
    }

    /// Recursively substitutes `__TESTROOT__` in every string value —
    /// directly, and inside nested arrays/dictionaries such as
    /// `DependentProductPaths` or `TestingEnvironmentVariables` — with an
    /// absolute path. `__TESTHOST__` is deliberately left alone: it refers
    /// to another field's own resolved value (the test host, not the
    /// products root), which for a framework or app-hosted unit test target
    /// — the only kinds `-only-testing:` narrowing applies to here — does
    /// not appear inside `TestBundlePath` in the first place.
    static func resolvingTestRootPlaceholders(in value: [String: Any], testRoot: String) -> [String: Any] {
        value.mapValues { resolvingTestRootPlaceholders(in: $0, testRoot: testRoot) }
    }

    private static func resolvingTestRootPlaceholders(in value: Any, testRoot: String) -> Any {
        if let string = value as? String {
            return string.replacingOccurrences(of: "__TESTROOT__", with: testRoot)
        }
        if let dictionary = value as? [String: Any] {
            return resolvingTestRootPlaceholders(in: dictionary, testRoot: testRoot)
        }
        if let array = value as? [Any] {
            return array.map { resolvingTestRootPlaceholders(in: $0, testRoot: testRoot) }
        }
        return value
    }

    /// Pure merge, exposed for tests: already-extracted per-mutant test
    /// target dictionaries in, one v2 batch document out. No disk access.
    public static func merge(
        _ items: [(configurationName: String, testTargets: [[String: Any]])]
    ) -> [String: Any] {
        let configurations = items.map { item in
            [
                "Name": item.configurationName,
                "IsEnabled": true,
                "TestTargets": item.testTargets
            ] as [String: Any]
        }
        return [
            "TestConfigurations": configurations,
            "__xctestrun_metadata__": ["FormatVersion": 2]
        ]
    }

    /// A v1 `.xctestrun`'s top level is one dictionary per test target,
    /// keyed by target name, alongside `__xctestrun_metadata__`. Every
    /// non-metadata entry is a target to fold in — normally exactly one,
    /// but a scheme with more than one enabled test target produces
    /// several, and all of them belong in the same configuration.
    ///
    /// A scheme with no checked-in `.xcscheme` (Xcode falls back to an
    /// autocreated one — confirmed against a real project whose
    /// `.xcodeproj` is entirely gitignored, so a fresh clone never has a
    /// scheme file at all) produces the *other* real xctestrun shape
    /// instead: a top-level `TestConfigurations` array, each element
    /// holding its own `TestTargets` array of the same per-target
    /// dictionaries v1 keeps flat. Both are real, current-Xcode output —
    /// which one a project produces depends on whether it has a checked-in
    /// scheme, not on anything this tool controls — so both are read
    /// rather than assuming the v1 shape and silently misinterpreting
    /// `TestConfigurations`/`TestPlan`/`ContainerInfo` as bogus targets
    /// (which is what treating every non-metadata top-level Dict as a
    /// target used to do here: `TestPlan` and `ContainerInfo` are
    /// dictionaries too).
    ///
    /// The v1 plist key is kept alongside its dictionary (not just the
    /// dictionary alone) because it is the target name `build(items:)`
    /// matches a `TestIdentifier.target` against — the same name that
    /// appears again inside the dictionary as `BlueprintName`/
    /// `ProductModuleName`, but the key is guaranteed present without
    /// depending on which of those two fields a given xctestrun happens to
    /// populate. The nested (`TestConfigurations`) shape has no such key,
    /// so its name is read from those two fields directly, preferring
    /// `BlueprintName` — the scheme's own name for the target, closest to
    /// what `TestIdentifier.target` names — and falling back to
    /// `ProductModuleName` when it is absent.
    static func testTargets(fromV1 plist: [String: Any]) -> [(name: String, target: [String: Any])] {
        if let configurations = plist["TestConfigurations"] as? [[String: Any]] {
            return configurations
                .flatMap { ($0["TestTargets"] as? [[String: Any]]) ?? [] }
                .compactMap { target -> (name: String, target: [String: Any])? in
                    guard let name = (target["BlueprintName"] as? String)
                        ?? (target["ProductModuleName"] as? String)
                    else { return nil }
                    return (name: name, target: target)
                }
        }
        return plist
            .filter { $0.key != "__xctestrun_metadata__" }
            .compactMap { key, value in (value as? [String: Any]).map { (name: key, target: $0) } }
    }
}
