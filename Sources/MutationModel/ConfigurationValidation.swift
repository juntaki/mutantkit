import Foundation

public struct ConfigurationIssue: Codable, Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable {
        case warning
        case error
    }

    public let severity: Severity
    public let path: String
    public let message: String

    public init(severity: Severity, path: String, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(path): \(message)" }
}

public enum ConfigurationValidator {
    /// - Parameter projectRoot: the real, on-disk directory `project
    ///   .derivedDataPath` will eventually be resolved against — the same
    ///   tree `WorkspaceManager` clones into every worker's sandbox,
    ///   symlinks and all (see `derivedDataPath`'s validation below for why
    ///   this can only be checked here, not purely from the configuration
    ///   string). `nil` when no real project directory is known yet (a
    ///   config-only check, or a unit test that never touches disk): the
    ///   component-string checks below still run, but the symlink check does
    ///   not, since there is nothing on disk to resolve it against.
    public static func validate(_ configuration: Configuration, projectRoot: URL? = nil) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []

        if configuration.version != 1 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "version",
                message: "Unsupported configuration version \(configuration.version); expected 1."
            ))
        }

        if let workers = configuration.execution.workers, workers < 1 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.workers",
                message: "Must be at least 1."
            ))
        }

        if let maxMutants = configuration.execution.budget.maxMutants, maxMutants < 1 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.budget.maxMutants",
                message: "Must be at least 1 when present."
            ))
        }

        if let maxDuration = configuration.execution.budget.maxDurationSeconds, maxDuration <= 0 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.budget.maxDurationSeconds",
                message: "Must be greater than zero when present."
            ))
        }

        issues += validateBudgetSampling(configuration.execution.budget)

        if configuration.timeouts.baselineSeconds <= 0 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "timeouts.baseline",
                message: "Must be greater than zero."
            ))
        }

        let mutant = configuration.timeouts.mutant
        if mutant.minimumSeconds <= 0 || mutant.maximumSeconds <= 0 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "timeouts.mutant",
                message: "Minimum and maximum timeout values must be greater than zero."
            ))
        }
        // Only meaningful for `.adaptive`: `.resolve(baselineDuration:)` never
        // reads `minimumSeconds` under `.fixed` (it returns `maximumSeconds`
        // outright), so a `.fixed` config that only sets `maximum` and leaves
        // `minimum` at its default would otherwise be flagged for a
        // relationship between two numbers that do not interact.
        if mutant.strategy == .adaptive, mutant.minimumSeconds > mutant.maximumSeconds {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "timeouts.mutant",
                message: "minimum must not exceed maximum."
            ))
        }
        if mutant.multiplier <= 0 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "timeouts.mutant.multiplier",
                message: "Must be greater than zero."
            ))
        }

        if configuration.execution.selectCoveringTests, !configuration.execution.measureCoverage {
            issues.append(ConfigurationIssue(
                severity: .warning,
                path: "execution.selectCoveringTests",
                message: "Per-test selection enables coverage instrumentation implicitly; "
                    + "setting measureCoverage=true makes that cost explicit in configuration."
            ))
        }

        if let batchSize = configuration.execution.testBatchSize, batchSize < 1 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.testBatchSize",
                message: "Must be at least 1 when present."
            ))
        }

        // Batching only batches mutants that have a known, narrowed test
        // selection (see `Configuration.execution.testBatchSize`). Without
        // `selectCoveringTests`, no mutant has one, so a `testBatchSize` set
        // here would take the batched code path while batching nothing — pure
        // overhead with no speedup, and a configuration that looks like it
        // asked for batching but silently got none.
        if configuration.execution.testBatchSize != nil,
           !configuration.execution.selectCoveringTests {
            issues.append(ConfigurationIssue(
                severity: .warning,
                path: "execution.testBatchSize",
                message: "Batching only applies to mutants with known covering tests; without selectCoveringTests it has no effect."
            ))
        }

        // `earlyAbortSelectedTests` wraps the covering-tests adapter, so it is
        // inert without `selectCoveringTests` (see RunCommand's test-adapter
        // selection). Flag it rather than silently ignoring the setting.
        if configuration.execution.earlyAbortSelectedTests,
           !configuration.execution.selectCoveringTests {
            issues.append(ConfigurationIssue(
                severity: .warning,
                path: "execution.earlyAbortSelectedTests",
                message: "Early-abort ordering only applies when selectCoveringTests is enabled; "
                    + "without it, earlyAbortSelectedTests has no effect."
            ))
        }

        // `.schemata` is now consumed — `RunCommand` dispatches to
        // `SchemataRunOrchestration` for it (SwiftPM only; see the schemata
        // production-integration plan). Unsupported project kinds fail
        // closed at run time instead (`SchemataRunOrchestration
        // .OrchestrationError.adapterNotSchemataCapable`), not here: this
        // preflight runs before the project adapter is even resolved, so it
        // cannot yet know whether `.schemata` is viable for this project.

        issues += validateDerivedDataPath(configuration.project.derivedDataPath, projectRoot: projectRoot)
        issues += validateXcodeTestTargets(configuration)

        return issues
    }

    private static func validateXcodeTestTargets(_ configuration: Configuration) -> [ConfigurationIssue] {
        guard configuration.tests.targets.isEmpty,
              configuration.project.kind == .xcodeProject || configuration.project.kind == .xcodeWorkspace
        else {
            return []
        }
        return [ConfigurationIssue(
            severity: .warning,
            path: "tests.targets",
            message: "No explicit test target is configured; xcodebuild may execute every test target in the scheme."
        )]
    }

    /// Every worker builds inside its own sandbox copy of the project, and
    /// `derivedDataPath(in:)` resolves a relative path against that
    /// per-worker workspace to keep each worker's build products isolated.
    /// An absolute path bypasses that entirely: every concurrent worker
    /// would pass xcodebuild the same `-derivedDataPath`, so one worker's
    /// build can overwrite the binaries another is about to test, and
    /// mutants get scored against each other's products. This is silently
    /// wrong output, not a workable-but-suboptimal configuration.
    ///
    /// A relative path is not automatically safe either: a security review
    /// of the first version of this check found `hasPrefix("/")` alone does
    /// not stop `../../shared-dd` (or any path with a `..` component) from
    /// resolving outside the per-worker sandbox just as an absolute path
    /// would — checked component-by-component, not with a substring search,
    /// since a component like `foo..bar` is a legal, harmless directory name
    /// that must not trip this on `..` as a substring.
    ///
    /// A follow-up review considered three more cases, resolved as follows:
    ///  - An empty string, `"."`, or a path made of nothing but `"."`
    ///    components resolves to the workspace root itself once
    ///    `URL.appendingPathComponent` collapses `"."` away — DerivedData
    ///    would then coexist with the sandbox's own source tree.
    ///  - A symlinked path component (e.g. `ExternalDD/build` where
    ///    `ExternalDD` is a symlink) is invisible to the two checks above:
    ///    they only see the configured *string*, and a symlink target is a
    ///    fact about the filesystem, not the string. It can only be checked
    ///    once a real directory exists to resolve it against — `projectRoot`
    ///    here — which is why this function, unlike the rest of
    ///    `ConfigurationValidator`, does filesystem I/O at all.
    ///    `WorkspaceManager` recreates symlinks rather than following them
    ///    when cloning the project into a worker's sandbox, so the same
    ///    symlink exists in every sandbox and checking it against the
    ///    original project root is representative of all of them.
    ///  - Windows-style separators (`..\foo`) and `~` expansion were also
    ///    considered and are non-issues: this tool only runs on macOS/Xcode,
    ///    where a backslash is a legal filename character, not a path
    ///    separator, and nothing in this codebase ever expands `~`.
    ///
    /// - Parameter projectRoot: see `validate`'s own parameter of the same
    ///   name. `nil` skips only the symlink check; the string-only checks
    ///   above always run.
    private static func validateDerivedDataPath(_ derivedDataPath: String?, projectRoot: URL?) -> [ConfigurationIssue] {
        guard let derivedDataPath else { return [] }

        let components = derivedDataPath.split(separator: "/", omittingEmptySubsequences: false)
        let escapesSandbox = derivedDataPath.hasPrefix("/") || components.contains("..")
        let resolvesToWorkspaceRoot = components.allSatisfy { $0.isEmpty || $0 == "." }

        if escapesSandbox {
            return [ConfigurationIssue(
                severity: .error,
                path: "project.derivedDataPath",
                message: "Must be a relative path with no '..' component, so each worker's sandbox "
                    + "resolves its own DerivedData strictly inside itself; '\(derivedDataPath)' "
                    + "would let every concurrent worker share or escape into the same directory, "
                    + "overwriting each other's build products."
            )]
        }
        if resolvesToWorkspaceRoot {
            return [ConfigurationIssue(
                severity: .error,
                path: "project.derivedDataPath",
                message: "Must not resolve to the workspace root itself; '\(derivedDataPath)' would put "
                    + "DerivedData directly on top of the sandbox's own source tree instead of in a "
                    + "dedicated subdirectory of it. Use a relative subdirectory, e.g. '.mutantkit/DerivedData'."
            )]
        }
        guard let projectRoot else { return [] }

        let resolvedRoot = resolvingSymlinksEvenIfMissing(projectRoot)
        let candidate = resolvingSymlinksEvenIfMissing(projectRoot.appendingPathComponent(derivedDataPath))
        let rootComponents = resolvedRoot.pathComponents
        let isStrictDescendant = candidate.pathComponents.count > rootComponents.count
            && Array(candidate.pathComponents.prefix(rootComponents.count)) == rootComponents
        guard !isStrictDescendant else { return [] }

        return [ConfigurationIssue(
            severity: .error,
            path: "project.derivedDataPath",
            message: "'\(derivedDataPath)' resolves to \(candidate.path), outside the project directory, "
                + "once symlinks are followed — most likely a symlinked path component. Every concurrent "
                + "worker's sandbox recreates that same symlink (see WorkspaceManager), so every worker "
                + "would still share or escape into \(candidate.path), exactly as an absolute or "
                + "'..'-traversing path would."
        )]
    }

    /// `URL.resolvingSymlinksInPath()` only resolves the parts of a path that
    /// actually exist on disk — confirmed against a real symlink: it happily
    /// resolves the symlink itself, but appending a component that does not
    /// exist yet (e.g. `ExternalDD/build`, where `build` is a directory
    /// `xcodebuild` has not created yet) leaves the whole path unresolved,
    /// symlink included. That is exactly the case that matters here: nothing
    /// requires `project.derivedDataPath` to already exist before a run
    /// starts, so trusting `resolvingSymlinksInPath()` alone would silently
    /// pass a validation this run right up until the moment a *second* run
    /// (or an earlier `xcodebuild` step) had already created that directory.
    /// This resolves symlinks in the longest ancestor that does exist, then
    /// reattaches whatever trailing components do not.
    private static func resolvingSymlinksEvenIfMissing(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var existingAncestor = url.standardizedFileURL
        var missingSuffix: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path), existingAncestor.pathComponents.count > 1 {
            missingSuffix.append(existingAncestor.lastPathComponent)
            existingAncestor = existingAncestor.deletingLastPathComponent()
        }
        return missingSuffix.reversed().reduce(existingAncestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }

    /// `stratifyBy: .operatorSubtype` has its own knob (`minimumPerOperator`)
    /// that only makes sense in that mode — split out so `validate` itself
    /// does not have to grow a branch per knob.
    private static func validateBudgetSampling(_ budget: BudgetSettings) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []

        if budget.selection == .v2 {
            issues += validateBudgetSelectionV2(budget)
        } else if budget.minimumPerStratum != nil || budget.weight != nil {
            // v1-only knobs still get evaluated below (`stratifyBy`), but v2's
            // own knobs are meaningless there — warn the same way
            // `minimumPerOperator` is warned about outside `.operatorSubtype`.
            if budget.minimumPerStratum != nil {
                issues.append(ConfigurationIssue(
                    severity: .warning,
                    path: "execution.budget.minimumPerStratum",
                    message: "Only applies under selection: v2; ignored otherwise."
                ))
            }
            if budget.weight != nil {
                issues.append(ConfigurationIssue(
                    severity: .warning,
                    path: "execution.budget.weight",
                    message: "Only applies under selection: v2; ignored otherwise."
                ))
            }
        }

        guard budget.stratifyBy == .operatorSubtype else {
            if budget.minimumPerOperator != nil {
                issues.append(ConfigurationIssue(
                    severity: .warning,
                    path: "execution.budget.minimumPerOperator",
                    message: "Only applies under stratifyBy: operatorSubtype; ignored otherwise."
                ))
            }
            return issues
        }

        // operatorSubtype has to know how many mutants it is dividing among
        // operators; without maxMutants it has no budget to allocate at all,
        // and doing nothing would defeat the entire point of asking for it.
        if budget.maxMutants == nil {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.budget.stratifyBy",
                message: "'operatorSubtype' requires execution.budget.maxMutants to be set."
            ))
        }
        if let minimumPerOperator = budget.minimumPerOperator, minimumPerOperator < 1 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.budget.minimumPerOperator",
                message: "Must be at least 1 when present."
            ))
        }
        return issues
    }

    /// `selection: .v2`'s own validation (ADR-0007 B.3/B.8). Weight
    /// *completeness* against the real operator set is not checkable here —
    /// operators aren't known until planning-time discovery — so only each
    /// configured value's range is checked; `BudgetSelectorV2.allocateCounts`
    /// itself enforces full-coverage-or-nothing at plan time and throws
    /// `.invalidWeightConfiguration` if violated (`MutationPlanner`
    /// surfaces that as `PlannerError.budgetSelectionV2Failed`).
    private static func validateBudgetSelectionV2(_ budget: BudgetSettings) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []

        // v2 has to know how many mutants it is dividing among strata; without
        // maxMutants there is no budget to allocate, same requirement as
        // stratifyBy: operatorSubtype above.
        if budget.maxMutants == nil {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.budget.selection",
                message: "'v2' requires execution.budget.maxMutants to be set."
            ))
        }
        if let minimumPerStratum = budget.minimumPerStratum, minimumPerStratum < 1 {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "execution.budget.minimumPerStratum",
                message: "Must be at least 1 when present."
            ))
        }
        if let weight = budget.weight {
            let weightValidRange = 1 ... 1_000_000
            for (stratumID, value) in weight.sorted(by: { $0.key < $1.key }) where !weightValidRange.contains(value) {
                issues.append(ConfigurationIssue(
                    severity: .error,
                    path: "execution.budget.weight.\(stratumID)",
                    message: "Must be an integer in \(weightValidRange), got \(value)."
                ))
            }
        }
        return issues
    }

    public static func hasErrors(_ configuration: Configuration) -> Bool {
        validate(configuration).contains { $0.severity == .error }
    }
}

/// JSON Schema draft for editor completion and static validation of the stable
/// public configuration surface. Kept in code so the schema version moves in
/// lock-step with `Configuration` rather than becoming a stale checked-in copy.
///
/// `ConfigurationSchemaParityTests` asserts every `Codable` key of every
/// settings struct appears here, so adding a public setting without adding it
/// to the schema fails the build. Extend a section by adding to `properties`
/// in both places at once.
public enum ConfigurationJSONSchema {
    public static let document = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://mutantkit.dev/schema/mutantkit-v1.json",
      "title": "MutantKit configuration",
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "version": { "type": "integer", "const": 1 },
        "project": {
          "type": "object",
          "properties": {
            "kind": { "enum": ["auto", "swiftPackageMacOS", "swiftPackageApple", "xcodeProject", "xcodeWorkspace"] },
            "path": { "type": ["string", "null"] },
            "scheme": { "type": ["string", "null"] },
            "destination": { "type": ["string", "null"] },
            "derivedDataPath": { "type": ["string", "null"] }
          }
        },
        "sources": {
          "type": "object",
          "properties": {
            "include": { "type": "array", "items": { "type": "string" } },
            "exclude": { "type": "array", "items": { "type": "string" } }
          }
        },
        "tests": {
          "type": "object",
          "properties": {
            "targets": { "type": "array", "items": { "type": "string" } },
            "extraArguments": { "type": "array", "items": { "type": "string" } },
            "parallel": { "type": "boolean" }
          }
        },
        "operators": {
          "type": "object",
          "properties": {
            "profile": { "enum": ["conservative", "default", "experimental"] },
            "disable": { "type": "array", "items": { "type": "string" } },
            "enable": { "type": "array", "items": { "type": "string" } }
          }
        },
        "execution": {
          "type": "object",
          "properties": {
            "strategy": { "enum": ["isolated", "schemata"] },
            "workers": { "type": ["integer", "null"], "minimum": 1 },
            "budget": {
              "type": "object",
              "properties": {
                "maxMutants": { "type": ["integer", "null"], "minimum": 1 },
                "maxDurationSeconds": { "type": ["number", "null"], "exclusiveMinimum": 0 },
                "seed": { "type": ["integer", "null"] },
                "stratifyBy": { "enum": ["subtype", "operatorSubtype", null] },
                "minimumPerOperator": { "type": ["integer", "null"], "minimum": 1 },
                "selection": { "enum": ["v1", "v2", null] },
                "minimumPerStratum": { "type": ["integer", "null"], "minimum": 1 },
                "weight": {
                  "type": ["object", "null"],
                  "additionalProperties": { "type": "integer", "minimum": 1, "maximum": 1000000 }
                }
              }
            },
            "diffBase": { "type": ["string", "null"] },
            "measureCoverage": { "type": "boolean" },
            "selectCoveringTests": { "type": "boolean" },
            "incrementalBuild": { "type": "boolean" },
            "retestKilledMutants": { "type": "boolean" },
            "confirmCrashKills": { "type": "boolean" },
            "confirmTimedOutMutants": { "type": "boolean" },
            "earlyAbortSelectedTests": { "type": "boolean" },
            "testBatchSize": { "type": ["integer", "null"], "minimum": 1 }
          }
        },
        "timeouts": {
          "type": "object",
          "properties": {
            "baseline": { "type": ["number", "string"] },
            "mutant": {
              "type": "object",
              "properties": {
                "strategy": { "enum": ["fixed", "adaptive"] },
                "multiplier": { "type": "number" },
                "minimum": { "type": ["number", "string"] },
                "maximum": { "type": ["number", "string"] },
                "overheadAllowance": { "type": ["number", "string"] }
              }
            },
            "terminationGracePeriod": { "type": ["number", "string"] }
          }
        },
        "reports": {
          "type": "array",
          "items": { "enum": ["console", "xcode", "json", "stryker-json", "html", "ci-summary"] },
          "uniqueItems": true
        },
        "qualityGate": {
          "type": "object",
          "properties": {
            "testedScore": {
              "type": "object",
              "properties": { "minimum": { "type": ["number", "null"] } }
            },
            "effectiveScore": {
              "type": "object",
              "properties": { "minimum": { "type": ["number", "null"] } }
            },
            "regression": {
              "type": "object",
              "properties": { "maximumDrop": { "type": ["number", "null"] } }
            },
            "survived": {
              "type": "object",
              "properties": { "newMaximum": { "type": ["integer", "null"] } }
            },
            "integrityViolations": {
              "type": "object",
              "properties": { "maximum": { "type": ["integer", "null"] } }
            }
          }
        }
      }
    }
    """#
}
