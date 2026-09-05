import Foundation
import MutationModel
import Testing

@Suite("Configuration validation")
struct ConfigurationValidationTests {
    @Test("default configuration has no validation errors")
    func defaultConfigurationIsValid() {
        let issues = ConfigurationValidator.validate(Configuration())
        #expect(!issues.contains { $0.severity == .error })
    }

    @Test("zero workers is rejected")
    func zeroWorkersIsRejected() {
        var configuration = Configuration()
        configuration.execution.workers = 0
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.workers" && $0.severity == .error })
    }

    @Test("invalid timeout range is rejected under the adaptive strategy")
    func invalidTimeoutRangeIsRejected() {
        var configuration = Configuration()
        configuration.timeouts.mutant.strategy = .adaptive
        configuration.timeouts.mutant.minimumSeconds = 100
        configuration.timeouts.mutant.maximumSeconds = 10
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "timeouts.mutant" && $0.severity == .error })
    }

    /// `.fixed` never reads `minimumSeconds` (see `MutantTimeoutSettings.resolve`),
    /// so a config that only sets `maximum` below the default `minimum` (30s) is
    /// not actually inconsistent — the two values don't interact under `.fixed`.
    /// Real-world regression: `Fixtures/HangingMutant/mutantkit.yml` sets
    /// `strategy: fixed, maximum: 20s` with no explicit `minimum`, which the
    /// unconditional check rejected the moment `plan` started calling the
    /// validator, even though the fixture was never actually inconsistent.
    @Test("a minimum above maximum is not flagged under the fixed strategy")
    func minimumAboveMaximumIsIgnoredUnderFixedStrategy() {
        var configuration = Configuration()
        configuration.timeouts.mutant.strategy = .fixed
        configuration.timeouts.mutant.maximumSeconds = 20
        // minimumSeconds left at its default (30) — greater than maximum, but
        // irrelevant under .fixed.
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "timeouts.mutant" && $0.message.contains("minimum must not exceed maximum") })
    }

    @Test("configuration schema exposes performance options")
    func schemaContainsPerformanceOptions() {
        #expect(ConfigurationJSONSchema.document.contains("selectCoveringTests"))
        #expect(ConfigurationJSONSchema.document.contains("incrementalBuild"))
        #expect(ConfigurationJSONSchema.document.contains("diffBase"))
        #expect(ConfigurationJSONSchema.document.contains("earlyAbortSelectedTests"))
        #expect(ConfigurationJSONSchema.document.contains("testBatchSize"))
    }

    @Test("testBatchSize below 1 is rejected")
    func testBatchSizeBelowOneIsRejected() {
        var configuration = Configuration()
        configuration.execution.testBatchSize = 0
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.testBatchSize" && $0.severity == .error })
    }

    @Test("noOpCanarySampleRate outside [0, 1] is rejected")
    func noOpCanarySampleRateOutOfRangeIsRejected() {
        var tooHigh = Configuration()
        tooHigh.execution.noOpCanarySampleRate = 1.5
        #expect(ConfigurationValidator.validate(tooHigh).contains { $0.path == "execution.noOpCanarySampleRate" && $0.severity == .error })

        var negative = Configuration()
        negative.execution.noOpCanarySampleRate = -0.1
        #expect(ConfigurationValidator.validate(negative).contains { $0.path == "execution.noOpCanarySampleRate" && $0.severity == .error })
    }

    @Test("testBatchSize without selectCoveringTests is flagged as ineffective")
    func batchSizeWithoutCoverageIsFlagged() {
        var configuration = Configuration()
        configuration.execution.testBatchSize = 8
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.testBatchSize" && $0.severity == .warning })
    }

    @Test("testBatchSize with selectCoveringTests is not flagged")
    func batchSizeWithCoverageIsAccepted() {
        var configuration = Configuration()
        configuration.execution.testBatchSize = 8
        configuration.execution.selectCoveringTests = true
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "execution.testBatchSize" })
    }

    @Test("earlyAbortSelectedTests without selectCoveringTests is flagged as ineffective")
    func earlyAbortWithoutCoverageIsFlagged() {
        var configuration = Configuration()
        configuration.execution.earlyAbortSelectedTests = true
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.earlyAbortSelectedTests" && $0.severity == .warning })
    }

    @Test("profileCoverageSkip under execution.profile: reference is flagged as having no effect")
    func profileCoverageSkipUnderReferenceIsFlagged() {
        var configuration = Configuration()
        configuration.execution.profileCoverageSkip = true
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.profileCoverageSkip" && $0.severity == .warning })
    }

    @Test("profileCoverageSkip under execution.profile: optimized is not flagged")
    func profileCoverageSkipUnderOptimizedIsNotFlagged() {
        var configuration = Configuration()
        configuration.execution.profileCoverageSkip = true
        configuration.execution.profile = .optimized
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "execution.profileCoverageSkip" })
    }

    // MARK: - execution.strategy

    @Test("execution.strategy: schemata is accepted — RunCommand dispatches to SchemataRunOrchestration")
    func schemataStrategyIsAccepted() {
        var configuration = Configuration()
        configuration.execution.strategy = .schemata
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "execution.strategy" })
    }

    @Test("the public config schema accepts both isolated and schemata for execution.strategy")
    func schemaAcceptsBothStrategies() {
        #expect(ConfigurationJSONSchema.document.contains(#""strategy": { "enum": ["isolated", "schemata"] }"#))
    }

    // MARK: - operatorSubtype sampling

    @Test("operatorSubtype without maxMutants is rejected")
    func operatorSubtypeRequiresMaxMutants() {
        var configuration = Configuration()
        configuration.execution.budget.stratifyBy = .operatorSubtype
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.budget.stratifyBy" && $0.severity == .error })
    }

    @Test("operatorSubtype with maxMutants and minimumPerOperator is accepted")
    func operatorSubtypeWithMaxMutantsIsAccepted() {
        var configuration = Configuration()
        configuration.execution.budget.maxMutants = 100
        configuration.execution.budget.stratifyBy = .operatorSubtype
        configuration.execution.budget.minimumPerOperator = 5
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.severity == .error })
    }

    @Test("minimumPerOperator below 1 is rejected")
    func minimumPerOperatorBelowOneIsRejected() {
        var configuration = Configuration()
        configuration.execution.budget.maxMutants = 100
        configuration.execution.budget.stratifyBy = .operatorSubtype
        configuration.execution.budget.minimumPerOperator = 0
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.budget.minimumPerOperator" && $0.severity == .error })
    }

    @Test("minimumPerOperator set without stratifyBy: operatorSubtype is flagged as inert")
    func minimumPerOperatorWithoutOperatorSubtypeIsFlagged() {
        var configuration = Configuration()
        configuration.execution.budget.minimumPerOperator = 5
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.budget.minimumPerOperator" && $0.severity == .warning })
    }

    @Test("configuration schema exposes operatorSubtype sampling fields")
    func schemaExposesOperatorSubtypeFields() {
        #expect(ConfigurationJSONSchema.document.contains("operatorSubtype"))
        #expect(ConfigurationJSONSchema.document.contains("minimumPerOperator"))
    }

    // MARK: - project.derivedDataPath

    /// Every worker builds inside its own sandbox copy of the project; an
    /// absolute `derivedDataPath` would be shared verbatim by every
    /// concurrent worker's `xcodebuild -derivedDataPath`, letting one
    /// worker's build overwrite the binaries another is about to test.
    @Test("an absolute project.derivedDataPath is rejected")
    func absoluteDerivedDataPathIsRejected() {
        var configuration = Configuration()
        configuration.project.derivedDataPath = "/tmp/SharedDerivedData"
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "project.derivedDataPath" && $0.severity == .error })
    }

    @Test("a relative project.derivedDataPath is accepted")
    func relativeDerivedDataPathIsAccepted() {
        var configuration = Configuration()
        configuration.project.derivedDataPath = ".mutantkit/DerivedData"
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "project.derivedDataPath" })
    }

    /// A security review of the first version of this check found that
    /// `hasPrefix("/")` alone does not stop a relative path from escaping the
    /// per-worker sandbox: `../../shared-dd` never starts with `/`, but
    /// resolving it against `workspace.appendingPathComponent(...)` still
    /// lands outside the workspace, exactly as an absolute path would —
    /// defeating the isolation guarantee this check exists to enforce.
    @Test("a relative project.derivedDataPath containing a '..' component is rejected")
    func traversalDerivedDataPathIsRejected() {
        for traversal in ["../shared-dd", "../../shared-dd", "a/../../b", ".."] {
            var configuration = Configuration()
            configuration.project.derivedDataPath = traversal
            let issues = ConfigurationValidator.validate(configuration)
            #expect(
                issues.contains { $0.path == "project.derivedDataPath" && $0.severity == .error },
                "\(traversal) should be rejected"
            )
        }
    }

    /// `..` as a substring of a legitimate directory name (not a path
    /// component on its own) must not be mistaken for a traversal attempt.
    @Test("a relative path containing '..' only as part of a longer component name is accepted")
    func dotDotSubstringInComponentNameIsAccepted() {
        var configuration = Configuration()
        configuration.project.derivedDataPath = "foo..bar/DerivedData"
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "project.derivedDataPath" })
    }

    @Test("no configured project.derivedDataPath is accepted")
    func unsetDerivedDataPathIsAccepted() {
        let issues = ConfigurationValidator.validate(Configuration())
        #expect(!issues.contains { $0.path == "project.derivedDataPath" })
    }

    /// An empty string or a path made of nothing but `"."` components is not
    /// a traversal, but `URL.appendingPathComponent` collapses it away, so it
    /// resolves to the workspace root itself — DerivedData would then coexist
    /// with the sandbox's own source tree instead of a dedicated subdirectory.
    @Test("an empty or all-dot project.derivedDataPath, which resolves to the workspace root, is rejected")
    func workspaceRootDerivedDataPathIsRejected() {
        for path in ["", ".", "./.", "././"] {
            var configuration = Configuration()
            configuration.project.derivedDataPath = path
            let issues = ConfigurationValidator.validate(configuration)
            #expect(
                issues.contains { $0.path == "project.derivedDataPath" && $0.severity == .error },
                "'\(path)' should be rejected"
            )
        }
    }

    /// `derivedDataPath` naming a symlinked directory is not visible from the
    /// configured string alone — `ExternalDD` looks like an ordinary relative
    /// component whether or not it is a symlink on disk. `WorkspaceManager`
    /// recreates symlinks rather than following them when it clones the
    /// project into a worker's sandbox, so the same symlink — pointing at the
    /// same outside location — exists in every sandbox: checking the
    /// configured path against the real project root, with symlinks
    /// resolved, catches this before a run starts, exactly as the
    /// string-only `..` check catches a literal traversal.
    @Test("a project.derivedDataPath that resolves outside the project root through a symlink is rejected")
    func symlinkEscapingDerivedDataPathIsRejected() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-ConfigValidationTests-\(UUID().uuidString)")
        let outsideTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-ConfigValidationTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: outsideTarget)
        }

        let symlink = projectRoot.appendingPathComponent("ExternalDD")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)

        var configuration = Configuration()
        configuration.project.derivedDataPath = "ExternalDD/build"
        let issues = ConfigurationValidator.validate(configuration, projectRoot: projectRoot)
        #expect(issues.contains { $0.path == "project.derivedDataPath" && $0.severity == .error })
    }

    /// The symlink check only runs when a real project root is supplied — a
    /// pure config-only check (no `projectRoot` argument, matching every
    /// other test in this file) has nothing on disk to resolve against, so
    /// it must not spuriously reject an ordinary-looking relative path.
    @Test("a project.derivedDataPath naming an ordinary directory is accepted when no projectRoot is given")
    func ordinaryDerivedDataPathIsAcceptedWithoutProjectRoot() {
        var configuration = Configuration()
        configuration.project.derivedDataPath = "ExternalDD/build"
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "project.derivedDataPath" })
    }

    /// A relative path that stays inside the project root, symlinks and all,
    /// must still be accepted once a `projectRoot` is supplied — the new
    /// check adds a symlink-escape guard, it does not regress the ordinary
    /// same-tree case.
    @Test("a project.derivedDataPath that stays inside the project root is accepted when projectRoot is given")
    func nonEscapingDerivedDataPathIsAcceptedWithProjectRoot() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-ConfigValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        var configuration = Configuration()
        configuration.project.derivedDataPath = ".mutantkit/DerivedData"
        let issues = ConfigurationValidator.validate(configuration, projectRoot: projectRoot)
        #expect(!issues.contains { $0.path == "project.derivedDataPath" })
    }

    // MARK: - Legacy key rejection (sampling/stratifyWithinOperatorBy superseded)

    /// A config written against the pre-`operatorSubtype` field names
    /// (`sampling: balancedByOperator`, `stratifyWithinOperatorBy: subtype`)
    /// must fail to decode loudly, not silently decode with both keys
    /// ignored — a silent ignore would mean a config that used to balance by
    /// operator quietly stops doing so and goes back to plain
    /// `stratifyBy: nil`/proportional sampling instead, which is exactly the
    /// starvation this whole feature exists to prevent.
    @Test("execution.budget.sampling is rejected, not silently ignored")
    func legacySamplingKeyIsRejected() throws {
        let json = """
        { "maxMutants": 100, "sampling": "balancedByOperator" }
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(BudgetSettings.self, from: Data(json.utf8))
        }
    }

    @Test("execution.budget.stratifyWithinOperatorBy is rejected, not silently ignored")
    func legacyStratifyWithinOperatorByKeyIsRejected() throws {
        let json = """
        { "maxMutants": 100, "stratifyWithinOperatorBy": "subtype" }
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(BudgetSettings.self, from: Data(json.utf8))
        }
    }

    /// The replacement key names, side by side, decode cleanly — this isn't
    /// a blanket "unknown keys error," only the two specific superseded ones.
    @Test("The replacement keys (stratifyBy: operatorSubtype, minimumPerOperator) decode cleanly")
    func replacementKeysDecodeCleanly() throws {
        let json = """
        { "maxMutants": 100, "stratifyBy": "operatorSubtype", "minimumPerOperator": 5 }
        """
        let budget = try JSONDecoder().decode(BudgetSettings.self, from: Data(json.utf8))
        #expect(budget.stratifyBy == .operatorSubtype)
        #expect(budget.minimumPerOperator == 5)
    }

    // MARK: - Budget Selection v2 is withdrawn from the configuration surface

    private func configuration(budget: BudgetSettings) -> Configuration {
        var configuration = Configuration()
        configuration.execution = ExecutionSettings(budget: budget)
        return configuration
    }

    /// `maxMutants` is set deliberately. Without it the pre-existing
    /// "'v2' requires execution.budget.maxMutants" branch fires on the same
    /// path, and this test would pass whether or not the withdrawal exists —
    /// the whole point is that a config with nothing else wrong with it is
    /// still rejected.
    @Test("A fully well-formed v2 configuration is still rejected, because v2 is withdrawn")
    func wellFormedBudgetSelectionV2IsRejected() {
        let issues = ConfigurationValidator.validate(
            configuration(budget: BudgetSettings(maxMutants: 100, selection: .v2))
        )
        let withdrawal = issues.first {
            $0.severity == .error
                && $0.path == "execution.budget.selection"
                && $0.message.contains("withdrawn")
        }
        #expect(withdrawal != nil, "expected a withdrawal error, got: \(issues)")
        #expect(withdrawal?.message.contains("selection: v1") == true, "the error must name the way out")
    }

    /// The CLI's own preflight (`ConfigurationPreflight.run`) fails closed on
    /// any `.error`, and every command that acts on a Configuration calls it,
    /// so this is what actually makes v2 unreachable rather than merely
    /// discouraged.
    @Test("hasErrors is true for a v2 configuration, so the CLI preflight fails closed on it")
    func budgetSelectionV2ProducesAHardError() {
        #expect(ConfigurationValidator.hasErrors(
            configuration(budget: BudgetSettings(maxMutants: 100, selection: .v2))
        ))
    }

    /// No collateral damage: withdrawing v2 must not reject the selector
    /// every existing configuration actually uses.
    @Test("v1 and an unset selection remain valid", arguments: [BudgetSelectionAlgorithm.v1, nil] as [BudgetSelectionAlgorithm?])
    func nonV2SelectionsRemainValid(selection: BudgetSelectionAlgorithm?) {
        let issues = ConfigurationValidator.validate(
            configuration(budget: BudgetSettings(maxMutants: 100, selection: selection))
        )
        #expect(!issues.contains { $0.severity == .error }, "unexpected errors: \(issues)")
    }

    /// The withdrawal is a validation decision, not a decoding one: the key
    /// still decodes, so an existing `selection: v2` config produces a named
    /// error rather than silently falling back to v1 sampling.
    @Test("selection: v2 still decodes, so the rejection is explicit rather than a silent fallback")
    func budgetSelectionV2StillDecodes() throws {
        let json = """
        { "maxMutants": 100, "selection": "v2" }
        """
        let budget = try JSONDecoder().decode(BudgetSettings.self, from: Data(json.utf8))
        #expect(budget.selection == .v2)
    }
}
