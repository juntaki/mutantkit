import Foundation
import MutationModel
import Yams

enum ConfigurationError: Error, CustomStringConvertible {
    case notFound(searched: [String])
    case unreadable(path: String, underlying: String)
    case malformed(path: String, underlying: String)
    case unsupportedVersion(path: String, found: Int, expected: Int)

    var description: String {
        switch self {
        case let .notFound(searched):
            """
            No mutantkit.yml found. Looked in:
            \(searched.map { "  \($0)" }.joined(separator: "\n"))
            Run `mutantkit init` to create one, or `mutantkit doctor` to check the environment first.
            """
        case let .unreadable(path, underlying):
            "Could not read \(path): \(underlying)"
        case let .malformed(path, underlying):
            "\(path) is not valid configuration: \(underlying)"
        case let .unsupportedVersion(path, found, expected):
            "\(path) declares version \(found); this tool understands version \(expected)."
        }
    }
}

/// Loads and resolves configuration.
///
/// Precedence, highest first: CLI flags > project config file > environment >
/// built-in defaults. Overrides are applied by the commands themselves after
/// loading, because only the command knows which flags the user actually passed
/// — a flag left at its default must not silently outrank the config file.
enum ConfigurationLoader {
    static let fileName = "mutantkit.yml"

    /// Environment overrides. Namespaced so they cannot collide with a project's
    /// own variables.
    private enum EnvironmentKey {
        static let scheme = "MUTANTKIT_SCHEME"
        static let destination = "MUTANTKIT_DESTINATION"
        static let workers = "MUTANTKIT_WORKERS"
        static let profile = "MUTANTKIT_OPERATOR_PROFILE"
    }

    static func locate(explicitPath: String?, projectRoot: URL) throws -> URL {
        if let explicitPath {
            let url = URL(fileURLWithPath: explicitPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConfigurationError.notFound(searched: [url.path])
            }
            return url
        }

        let candidate = projectRoot.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ConfigurationError.notFound(searched: [candidate.path])
        }
        return candidate
    }

    static func load(
        explicitPath: String?,
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Configuration {
        let url = try locate(explicitPath: explicitPath, projectRoot: projectRoot)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigurationError.unreadable(path: url.path, underlying: error.localizedDescription)
        }

        var configuration: Configuration
        do {
            configuration = try YAMLDecoder().decode(Configuration.self, from: data)
        } catch {
            throw ConfigurationError.malformed(path: url.path, underlying: "\(error)")
        }

        guard configuration.version == 1 else {
            throw ConfigurationError.unsupportedVersion(
                path: url.path, found: configuration.version, expected: 1
            )
        }

        applyEnvironment(environment, to: &configuration)
        return configuration
    }

    /// Environment sits *below* the config file, so it only fills gaps the file
    /// left. A CI variable must not silently redirect a run that the checked-in
    /// config already pinned.
    private static func applyEnvironment(_ environment: [String: String], to configuration: inout Configuration) {
        if configuration.project.scheme == nil, let scheme = environment[EnvironmentKey.scheme] {
            configuration.project.scheme = scheme
        }
        if configuration.project.destination == nil, let destination = environment[EnvironmentKey.destination] {
            configuration.project.destination = destination
        }
        if configuration.execution.workers == nil,
           let workers = environment[EnvironmentKey.workers].flatMap(Int.init) {
            configuration.execution.workers = workers
        }
        if let raw = environment[EnvironmentKey.profile], let profile = OperatorProfile(rawValue: raw) {
            configuration.operators.profile = profile
        }
    }

    /// The starting config `init` writes. Commented, because a config file the
    /// user cannot read is a config file the user will not maintain.
    /// The `$schema` URL matches `ConfigurationJSONSchema.document`'s own
    /// `$id` exactly (see that type's doc comment for the pinned-tag
    /// versioning convention) — this is a real, GitHub-hosted copy of the
    /// same JSON Schema, not a placeholder, so editors that understand the
    /// `yaml-language-server` directive get live completion and validation
    /// against it.
    private static let schemaURL = "https://raw.githubusercontent.com/juntaki/mutantkit/v0.2.0/Schema/mutantkit-v1.json"

    static func template(for kind: ProjectKind, scheme: String?, destination: String?, testTargets: [String]) -> String {
        var lines = [
            "# yaml-language-server: $schema=\(schemaURL)",
            "# Generated by `mutantkit init`. See README.md for the full reference.",
            "version: 1",
            "",
            "project:",
            "  kind: \(kind.rawValue)"
        ]

        if let scheme { lines.append("  scheme: \(scheme)") }
        if let destination { lines.append("  destination: \(destination)") }

        lines.append(contentsOf: [
            "",
            "sources:",
            "  include:",
            "    - Sources/**",
            "  exclude:"
        ])
        lines.append(contentsOf: SourceSettings.defaultExcludes.map { "    - \"\($0)\"" })

        lines.append(contentsOf: ["", "tests:", "  targets:"])
        if testTargets.isEmpty {
            lines.append("    # No test target detected. Add yours here, or run `mutantkit doctor`.")
            lines.append("    []")
        } else {
            lines.append(contentsOf: testTargets.map { "    - \($0)" })
        }

        lines.append(contentsOf: operatorsAndExecutionLines(for: kind))

        lines.append(contentsOf: [
            "  budget:",
            "    maxMutants: 50",
            "",
            "timeouts:",
            "  baseline: 10m",
            "  mutant:",
            "    # `adaptive` derives the limit from the measured baseline. A mutant",
            "    # that deletes a continuation resume hangs forever; this ends it.",
            "    strategy: adaptive",
            "    multiplier: 3",
            "    # Added on top of baseline x multiplier. The baseline measures a",
            "    # PASSING suite, but a mutant that gets killed makes it fail, and",
            "    # failing costs extra fixed time (diagnostics, result bundles) that",
            "    # does not shrink with the suite. Without this, small suites report",
            "    # killed mutants as `timedOut` and drop them from the score.",
            "    overheadAllowance: 60s",
            "    minimum: 30s",
            "    maximum: 5m",
            "",
            "reports:",
            "  - console",
            "  - json",
            ""
        ])

        return lines.joined(separator: "\n")
    }

    /// The `operators:`/`execution:` sections of the generated template,
    /// including the workers/simulatorPool/incrementalBuild/
    /// selectCoveringTests branching those benchmark numbers justify. Split
    /// out of `template` itself purely to keep that function's body a
    /// reasonable length; the content and behavior are unchanged.
    private static func operatorsAndExecutionLines(for kind: ProjectKind) -> [String] {
        var lines = [
            "",
            "operators:",
            "  # conservative = high-confidence only (use for pull requests)",
            "  # default      = every operator enabled by default (nightly)",
            "  # experimental = everything, including noisy operators (weekly)",
            "  profile: default",
            "  disable: []",
            "",
            "execution:",
            "  # `isolated` rebuilds once per mutant. Slow, and the only mode whose",
            "  # results are the reference for every faster mode added later.",
            "  strategy: isolated"
        ]

        // Phase C13 (competitive-parity program): a real 4-way local
        // benchmark against a real, large production iOS app (32-100 real
        // mutants depending on the leg) compared this template's own
        // untuned defaults against three tuned profiles. The untuned
        // defaults measured here (no incrementalBuild/selectCoveringTests/
        // simulatorPool at all) took ~80.6s/mutant (32-mutant leg) —
        // slower than even the most basic tuned profile (N=1,
        // incrementalBuild + selectCoveringTests only, ~56.2s/mutant at
        // 100-mutant scale), let alone the production-grade N=2
        // simulatorPool profile the same 100-mutant benchmark proved
        // (~26s/mutant, 2.17x speedup vs. that N=1 *tuned* reference —
        // not the untuned defaults, a separate, smaller measurement —
        // 100/100 outcome parity with it, 0 integrity violations). A new
        // user landing on this generated file with zero manual tuning was
        // getting the worst realistic outcome, not a reasonable default.
        //
        // `workers: 2` (not `auto`) and `simulatorPool: true` are only
        // meaningful for a kind that actually leases a real Simulator —
        // `simulatorPool` is a no-op for a host-only `swiftPackageMacOS`
        // run, and `workers: auto` (half the core count) is the real,
        // already-proven default there.
        //
        // `workers: 2`, not a higher number: a targeted replay
        // investigation (Phase C13, item ③) found N=4's own one real
        // outcome disagreement against N=1/N=2 could not be cleared to
        // N=2's confidence level (see PROGRESS.md's "③ N=4 targeted
        // replay" entry) — N=2 is the production-grade recommendation
        // here specifically because N=4 remains an experimental setting,
        // not because N=2 is assumed safer without evidence.
        if kind == .xcodeProject || kind == .xcodeWorkspace || kind == .swiftPackageApple {
            lines.append(contentsOf: [
                "  workers: 2",
                "  # Provisions one real simulator clone per worker so `workers > 1`",
                "  # genuinely parallelizes test execution across distinct devices,",
                "  # instead of serializing on one shared destination. iOS/tvOS/",
                "  # watchOS Simulator kinds only; no effect for a host-only SwiftPM",
                "  # package. `workers: 2` (not a higher number) is this repo's own",
                "  # real, measured production-grade profile — see README.md's",
                "  # \"Recommended production profile\" section.",
                "  simulatorPool: true",
                "  # Reuses one persistent, incrementally-recompiled sandbox per",
                "  # worker across its mutants instead of a fresh build for each.",
                "  incrementalBuild: true",
                "  # Narrows each mutant's test run to only the tests that cover its",
                "  # mutated line. The single largest speedup measured before",
                "  # touching incrementalBuild/simulatorPool at all.",
                "  selectCoveringTests: true"
            ])
        } else {
            lines.append("  workers: auto")
        }
        return lines
    }
}
