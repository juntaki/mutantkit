import Foundation
import MutationExecution
import MutationModel

/// Reads test outcomes out of an `.xcresult` bundle.
///
/// This type is the reason the module can be trusted. Test outcomes are read from
/// the result bundle's structured data and from nothing else — never from
/// matching patterns against a runner's stdout. Stdout is a human-readable
/// stream whose wording changes between Xcode releases and differs entirely
/// between XCTest and Swift Testing; treating it as data is how a Swift Testing
/// failure gets reported as a runtime error, and a mutant that was actually
/// caught gets scored as survived.
///
/// Both XCTest and Swift Testing write into the same bundle and are read back
/// through the same fields here, so the caller never needs to know which
/// framework produced a result.
public struct XCResultAdapter: Sendable {
    /// How long `xcresulttool` gets. It reads a local bundle, so this only has to
    /// be generous enough for a very large one.
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 120) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// A parsed bundle: what ran, what failed, and how we know.
    public struct Outcome: Sendable {
        public let status: TestRunStatus
        public let summary: TestOutcomeSummary
        public let diagnosis: String
    }

    // MARK: - Parsing

    /// Classifies a result bundle.
    ///
    /// Never throws: an unreadable bundle is itself a diagnosable outcome
    /// (`.infrastructureFailure`), not an error for the caller to invent a
    /// meaning for.
    ///
    /// - Parameter expectedTestCount: how many tests this run was narrowed to
    ///   (`selectedTests.count` at the call site) when the caller knows an exact
    ///   number in advance — `nil` for an unnarrowed, whole-suite-list run, where
    ///   no such number is known ahead of time. See `classify(summary:expectedTestCount:)`.
    public func classify(resultBundle: URL, workingDirectory: URL, expectedTestCount: Int? = nil) async -> Outcome {
        guard FileManager.default.fileExists(atPath: resultBundle.path) else {
            return infrastructure(
                """
                No result bundle was written at \(resultBundle.lastPathComponent). The test \
                run produced no structured output, so its outcome is unknown.
                """
            )
        }

        let arguments = [
            "xcresulttool", "get", "test-results", "summary",
            "--path", resultBundle.path,
            "--compact"
        ]

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return infrastructure("Could not run xcresulttool: \(error)")
        }

        guard result.succeeded else {
            return infrastructure(
                """
                xcresulttool could not read \(resultBundle.lastPathComponent) (exit \
                \(result.exitCode)): \
                \(OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                """
            )
        }

        let summary: TestSummaryJSON
        do {
            summary = try JSONDecoder().decode(TestSummaryJSON.self, from: result.standardOutput)
        } catch {
            return infrastructure(
                """
                xcresulttool produced JSON this version does not understand \
                (\(error)). The outcome cannot be established, so it is not guessed.
                """
            )
        }

        return classify(summary: summary, expectedTestCount: expectedTestCount)
    }

    /// Turns a decoded summary into an outcome.
    ///
    /// Separate from the process call so the classification rules are testable
    /// against fixture JSON without an Xcode install.
    ///
    /// - Parameter expectedTestCount: when non-`nil`, a run narrowed to exactly
    ///   this many tests (a known `selectedTests` set, not an unnarrowed whole-
    ///   target list) that reports *fewer* than this many total tests — with
    ///   nothing else here (no crash, no timeout, no attributable failure) to
    ///   explain the shortfall — is `.infrastructureFailure`, never `.passed`.
    ///   A target whose bundle contributes nothing at all to the summary (the
    ///   `TargetATests`/`TargetBTests` shape a real reproduction confirmed:
    ///   see `XCResultAdapterTests`) leaves no failure record of its own kind
    ///   for `isSystemFailure`/`isCrash`/etc. to catch — only the missing count
    ///   itself proves something did not run. Never applied when `nil`: an
    ///   unnarrowed run has no independently-known expected count to compare
    ///   against, and legitimate test-plan/filtering differences mean a lower
    ///   count there is not automatically suspicious the way a narrowed
    ///   selection's own exact, pre-computed count is.
    func classify(summary: TestSummaryJSON, expectedTestCount: Int? = nil) -> Outcome {
        let failures = summary.testFailures ?? []
        let outcomeSummary = TestOutcomeSummary(
            total: summary.totalTestCount,
            passed: summary.passedTests,
            failed: summary.failedTests,
            failingTests: failures.map(\.identifier).sorted(),
            durationSeconds: summary.durationSeconds
        )

        // Zero tests is never a pass. A bundle that failed to launch, a filter that
        // matched nothing, and a suite that genuinely ran are indistinguishable in
        // the counts alone — but for a mutation run, "nothing ran" can only mean the
        // harness is broken, since the baseline proved tests exist.
        if summary.totalTestCount == 0 {
            return Outcome(
                status: .infrastructureFailure,
                summary: outcomeSummary,
                diagnosis: """
                The result bundle records no tests at all (result: \(summary.result)). \
                Nothing ran, so this is a harness failure rather than a test outcome.
                """
            )
        }

        // See `systemFailureOutcome`'s own doc comment for what this catches
        // and why it is checked against `failures.count`, not `summary.totalTestCount`.
        if let outcome = systemFailureOutcome(failures: failures, outcomeSummary: outcomeSummary) {
            return outcome
        }

        // A crash and an assertion failure both land here as "Failed" with a
        // non-zero count, so the counts cannot separate them. Apple classifies the
        // distinction inside the failure record itself, which is what we read.
        let crashes = failures.filter(\.isCrash)
        if !crashes.isEmpty {
            return Outcome(
                status: .crashed,
                summary: outcomeSummary,
                diagnosis: """
                The test runner crashed in \(describe(crashes)). \
                \(crashes[0].failureText)
                """
            )
        }

        // Same precedence slot as `isCrash` above (checked after it, so a
        // crash still wins if a bundle somehow reports both): any failure
        // in this configuration whose own structured text proves XCTest's
        // native per-test allowance cut it off is enough to call the whole
        // configuration timed out, exactly like one crashing test call is
        // enough to call the whole configuration crashed.
        let nativeTimeouts = failures.filter(\.isNativeTimeout)
        if !nativeTimeouts.isEmpty {
            return Outcome(
                status: .timedOut,
                summary: outcomeSummary,
                diagnosis: """
                XCTest's own execution-time allowance was exceeded in \(describe(nativeTimeouts)). \
                \(nativeTimeouts[0].failureText)
                """
            )
        }

        if let outcome = failedCountOutcome(summary: summary, failures: failures, outcomeSummary: outcomeSummary) {
            return outcome
        }

        // Checked last, immediately before the "Passed" branch it exists to
        // guard, so every failure-shaped explanation above still takes
        // precedence. See the function's own doc comment for what this catches.
        if let outcome = shortfallOutcome(summary: summary, expectedTestCount: expectedTestCount, outcomeSummary: outcomeSummary) {
            return outcome
        }

        switch summary.result {
        case "Passed":
            return Outcome(
                status: .passed,
                summary: outcomeSummary,
                diagnosis: "All \(summary.passedTests) of \(summary.totalTestCount) tests passed."
            )
        case "Failed":
            // The bundle says failed but names no failing test: the run died outside
            // any test, so attributing it to the mutant would be a fabrication.
            return Outcome(
                status: .infrastructureFailure,
                summary: outcomeSummary,
                diagnosis: """
                The result bundle reports failure but names no failing test. The run \
                failed outside of any test, which is an environment problem rather \
                than a test outcome.
                """
            )
        default:
            return Outcome(
                status: .infrastructureFailure,
                summary: outcomeSummary,
                diagnosis: """
                The result bundle reports an inconclusive result (\(summary.result)) \
                with no failing tests, so the outcome cannot be established.
                """
            )
        }
    }
}

extension XCResultAdapter {
    // MARK: - Batch parsing

    /// Classifies every configuration in a batched result bundle at once —
    /// two `xcresulttool` calls instead of one per mutant, same as the batch
    /// itself was one `xcodebuild` invocation instead of one per mutant.
    ///
    /// Two calls, not one, because the two commands answer different
    /// questions and neither answers both on its own:
    /// `test-results summary` gives each configuration's own, real
    /// aggregate counts (`devicesAndConfigurations`) but attributes
    /// failures through one flat, batch-wide `testFailures` array with no
    /// per-configuration scoping at all; `test-results tests` gives a tree
    /// in which a `Test Plan Configuration` node nested under a `Test Case`
    /// exists *because* that one configuration ran that one test, so it is
    /// scoped by construction. Reuses `classify(summary:)` unchanged:
    /// each configuration's own counts and its own tree-derived failing
    /// tests are assembled into the same `TestSummaryJSON` shape a single,
    /// unbatched bundle would have produced, so a crash, a plain assertion
    /// failure and a clean pass are told apart by the identical rule
    /// regardless of which path produced the bundle.
    ///
    /// - Parameter configurationTestIdentifiers: every `configurationName`
    ///   the batch was built with (see `BatchXCTestRunBuilder`), mapped to
    ///   the `-only-testing:`-style identifiers it was narrowed to. A
    ///   configuration named here but absent from either the bundle's own
    ///   `devicesAndConfigurations` or its `test-results tests` tree is
    ///   reported `.infrastructureFailure` rather than silently missing: a
    ///   batch-level failure severe enough to lose a configuration entirely
    ///   must never read as an unproven verdict skipped over in silence.
    public func classifyBatch(
        resultBundle: URL,
        workingDirectory: URL,
        configurationTestIdentifiers: [String: [String]]
    ) async -> [String: Outcome] {
        let configurationNames = Array(configurationTestIdentifiers.keys)

        guard FileManager.default.fileExists(atPath: resultBundle.path) else {
            let outcome = infrastructure(
                """
                No result bundle was written at \(resultBundle.lastPathComponent). The batch \
                test run produced no structured output, so no configuration in it has a known outcome.
                """
            )
            return Dictionary(uniqueKeysWithValues: configurationNames.map { ($0, outcome) })
        }

        let summaryArguments = [
            "xcresulttool", "get", "test-results", "summary",
            "--path", resultBundle.path,
            "--compact"
        ]

        let summaryResult: ProcessResult
        do {
            summaryResult = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: summaryArguments,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            let outcome = infrastructure("Could not run xcresulttool: \(error)")
            return Dictionary(uniqueKeysWithValues: configurationNames.map { ($0, outcome) })
        }

        guard summaryResult.succeeded else {
            let outcome = infrastructure(
                """
                xcresulttool could not read \(resultBundle.lastPathComponent) (exit \
                \(summaryResult.exitCode)): \
                \(OutputRedactor.redactAndTruncate(summaryResult.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                """
            )
            return Dictionary(uniqueKeysWithValues: configurationNames.map { ($0, outcome) })
        }

        let batch: BatchTestSummaryJSON
        do {
            batch = try JSONDecoder().decode(BatchTestSummaryJSON.self, from: summaryResult.standardOutput)
        } catch {
            let outcome = infrastructure(
                """
                xcresulttool produced batch summary JSON this version does not understand \
                (\(error)). No configuration's outcome can be established, so none is guessed.
                """
            )
            return Dictionary(uniqueKeysWithValues: configurationNames.map { ($0, outcome) })
        }

        let treeArguments = [
            "xcresulttool", "get", "test-results", "tests",
            "--path", resultBundle.path,
            "--compact"
        ]

        let treeResult: ProcessResult
        do {
            treeResult = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: treeArguments,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            let outcome = infrastructure("Could not run xcresulttool: \(error)")
            return Dictionary(uniqueKeysWithValues: configurationNames.map { ($0, outcome) })
        }

        guard treeResult.succeeded else {
            let outcome = infrastructure(
                """
                xcresulttool could not read the per-test hierarchy of \
                \(resultBundle.lastPathComponent) (exit \(treeResult.exitCode)): \
                \(OutputRedactor.redactAndTruncate(treeResult.combinedOutput, limit: 400)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                """
            )
            return Dictionary(uniqueKeysWithValues: configurationNames.map { ($0, outcome) })
        }

        let tree: BatchTestNodesJSON
        do {
            tree = try JSONDecoder().decode(BatchTestNodesJSON.self, from: treeResult.standardOutput)
        } catch {
            let outcome = infrastructure(
                """
                xcresulttool produced per-test hierarchy JSON this version does not understand \
                (\(error)). No configuration's outcome can be established, so none is guessed.
                """
            )
            return Dictionary(uniqueKeysWithValues: configurationNames.map { ($0, outcome) })
        }

        return classify(batch: batch, tree: tree, configurationTestIdentifiers: configurationTestIdentifiers)
    }

    /// Separate from the process calls so the per-configuration attribution
    /// rules are testable against fixture JSON without a toolchain.
    ///
    /// `tree` is what makes attribution safe when two configurations'
    /// narrowed selections overlap on a covering test (an ordinary outcome
    /// of `selectCoveringTests` choosing covering tests per-mutant: two
    /// mutations in the same function are commonly covered by the same
    /// test). A batch-wide, flat failure list — matched by identifier
    /// membership — cannot tell "this configuration's own run of the
    /// shared test failed" apart from "a *sibling* configuration's run of
    /// the same-named test failed, and this configuration merely also
    /// includes that identifier in its own selection". Confirmed against a
    /// real batch: a shared test that failed in one configuration's own
    /// run was, under the old flat-matching rule, also attributed to two
    /// sibling configurations whose own `devicesAndConfigurations` counts
    /// showed zero failures. The tree does not have this ambiguity — a
    /// `Test Plan Configuration` node only exists nested under a `Test
    /// Case` node because that one configuration ran that one test, so
    /// its own `result` ("Passed"/"Failed"/"Skipped") is that
    /// configuration's own verdict for that test, never a neighbor's.
    func classify(
        batch: BatchTestSummaryJSON,
        tree: BatchTestNodesJSON,
        configurationTestIdentifiers: [String: [String]]
    ) -> [String: Outcome] {
        let byConfiguration = Dictionary(
            uniqueKeysWithValues: (batch.devicesAndConfigurations ?? []).map {
                ($0.testPlanConfiguration.configurationName, $0)
            }
        )
        let (ownFailuresByConfiguration, configurationsInTree) = Self.ownFailures(in: tree.testNodes)

        var outcomes: [String: Outcome] = [:]
        for name in configurationTestIdentifiers.keys {
            guard let device = byConfiguration[name] else {
                outcomes[name] = infrastructure(
                    """
                    The batch result bundle has no record of configuration \(name) at all. \
                    Every other configuration in the batch may have run fine; this one's outcome \
                    is unknown, not a pass.
                    """
                )
                continue
            }

            guard configurationsInTree.contains(name) else {
                outcomes[name] = infrastructure(
                    """
                    The batch result bundle's per-test hierarchy has no record of configuration \
                    \(name) at all, even though its own aggregate counts exist. Its outcome cannot \
                    be attributed to any specific test, so it is unknown, not a pass.
                    """
                )
                continue
            }

            let ownFailures = ownFailuresByConfiguration[name] ?? []

            // The device's own count is real — `xcresulttool` reports it
            // directly per configuration — but this configuration's own
            // nodes in the tree name no failing test. Confirmed against a
            // real batch of complexity `XcodeBatchTestingAcceptanceTests`'s
            // tiny fixture never approaches: a configuration can fail for a
            // reason that produces no test-identifier at all (the same
            // "test runner failed to install or launch" shape
            // `isSystemFailure` recognizes for a single, unbatched mutant).
            // Passing an empty `testFailures` through to `classify(summary:)`
            // here would hit its `failedTests > 0` fallback and report a
            // proven `killedByAssertion` backed by no identifiable evidence
            // at all — reporting `.infrastructureFailure` instead is the
            // fail-closed reading: this configuration failed for an unknown
            // reason, which is a fact about the batch, not a proven kill.
            guard device.failedTests == 0 || !ownFailures.isEmpty else {
                outcomes[name] = infrastructure(
                    """
                    This configuration reports \(device.failedTests) failed test(s), but none of \
                    its own nodes in the batch's per-test hierarchy name a failing test. The failure \
                    cannot be attributed to a specific test, so it is not scored as a kill.
                    """
                )
                continue
            }

            let synthetic = TestSummaryJSON(
                result: device.failedTests > 0 ? "Failed" : "Passed",
                totalTestCount: device.passedTests + device.failedTests
                    + device.skippedTests + device.expectedFailures,
                passedTests: device.passedTests,
                failedTests: device.failedTests,
                skippedTests: device.skippedTests,
                expectedFailures: device.expectedFailures,
                testFailures: ownFailures,
                startTime: nil,
                finishTime: nil
            )
            outcomes[name] = classify(summary: synthetic)
        }
        return outcomes
    }

    /// Walks the per-test hierarchy once, collecting each configuration's
    /// own failing tests plus the full set of configuration names that
    /// appear anywhere in it (even with zero failures) — the latter is
    /// what tells "this configuration ran clean" apart from "this
    /// configuration is entirely missing from the tree", which the caller
    /// must fail closed on rather than silently reading as a pass.
    ///
    /// A `Test Plan Configuration` node is only ever found nested directly
    /// under a `Test Case` node (confirmed against real batch bundles), so
    /// only that nesting is read; a target name is threaded down from the
    /// nearest ancestor `Unit test bundle` node the same way
    /// `XcodeBuildAdapter.parseTestIdentifiers` already does for the
    /// unbatched enumeration path.
    private static func ownFailures(
        in nodes: [BatchTestNodesJSON.Node]
    ) -> (byConfiguration: [String: [TestSummaryJSON.Failure]], configurationNames: Set<String>) {
        var failures: [String: [TestSummaryJSON.Failure]] = [:]
        var configurationNames: Set<String> = []

        func walk(_ node: BatchTestNodesJSON.Node, target: String?) {
            let currentTarget = node.nodeType == "Unit test bundle" ? node.name : target

            if node.nodeType == "Test Case" {
                for configuration in node.children ?? [] where configuration.nodeType == "Test Plan Configuration" {
                    guard let configurationName = configuration.name else { continue }
                    configurationNames.insert(configurationName)
                    guard configuration.result == "Failed" else { continue }

                    let failureText = (configuration.children ?? [])
                        .filter { $0.nodeType == "Failure Message" }
                        .compactMap(\.name)
                        .joined(separator: "\n")
                    let identifier = node.nodeIdentifier ?? node.name ?? ""
                    failures[configurationName, default: []].append(
                        TestSummaryJSON.Failure(
                            testName: node.name ?? identifier,
                            targetName: currentTarget ?? "",
                            failureText: failureText,
                            testIdentifierString: identifier,
                            durationInSeconds: configuration.durationInSeconds
                        )
                    )
                }
                // A Test Case node's only meaningful children are its Test
                // Plan Configuration nodes, already read above.
                return
            }

            for child in node.children ?? [] {
                walk(child, target: currentTarget)
            }
        }

        for node in nodes { walk(node, target: nil) }
        return (failures, configurationNames)
    }

    // MARK: - Support

    private func describe(_ failures: [TestSummaryJSON.Failure]) -> String {
        let names = failures.prefix(3).map(\.identifier)
        let remainder = failures.count - names.count
        let listed = names.joined(separator: ", ")
        return remainder > 0 ? "\(listed) and \(remainder) more" : listed
    }

    private func infrastructure(_ diagnosis: String) -> Outcome {
        // The summary is zeroed rather than omitted: a caller must not be able to
        // read "0 failed" here as evidence that nothing failed.
        Outcome(
            status: .infrastructureFailure,
            summary: TestOutcomeSummary(
                total: 0, passed: 0, failed: 0, failingTests: [], durationSeconds: nil
            ),
            diagnosis: diagnosis
        )
    }
}

private extension XCResultAdapter {
    /// Handles the case where the aggregate `failedTests` count and the
    /// failure-record list disagree about whether an identified failure
    /// exists — `nil` when neither applies, so the caller falls through to
    /// `summary.result`.
    ///
    /// The count is real, but if no failure record names which test it was,
    /// attributing it to any specific test would be a fabrication — the same
    /// fail-closed guard the batch path applies per configuration (see
    /// `classify(batch:tree:configurationTestIdentifiers:)`), mirrored here
    /// for the unbatched, single-run path.
    func failedCountOutcome(
        summary: TestSummaryJSON,
        failures: [TestSummaryJSON.Failure],
        outcomeSummary: TestOutcomeSummary
    ) -> Outcome? {
        guard summary.failedTests == 0 || !failures.isEmpty else {
            return Outcome(
                status: .infrastructureFailure,
                summary: outcomeSummary,
                diagnosis: """
                \(summary.failedTests) test(s) reportedly failed, but no failure record \
                names which one. The failure cannot be attributed to a specific test, so \
                it is not scored as a kill.
                """
            )
        }

        guard !failures.isEmpty else { return nil }

        return Outcome(
            status: .failed,
            summary: outcomeSummary,
            diagnosis: """
            \(summary.failedTests) of \(summary.totalTestCount) tests failed, \
            including \(describe(failures)).
            """
        )
    }

    /// The test runner itself can fail to install or launch — a simulator-level
    /// fault (observed: CoreSimulator's SBMainWorkspace refusing a launch as
    /// "Busy" after a rapid preceding install/teardown) that never reached any
    /// test. Apple's result bundle represents this as a synthetic one-"test"
    /// failure ("<App> encountered an error") rather than as a zero-test bundle,
    /// so it does not hit `classify(summary:expectedTestCount:)`'s own
    /// `totalTestCount == 0` guard. Scoring it as `.failed` would report a
    /// mutant as caught by a test that never ran. Only trusted when every
    /// *recorded failure* is this synthetic kind — a real failure alongside it
    /// should still be attributed normally.
    ///
    /// Checked against `failures.count`, not the summary's own
    /// `totalTestCount`: a codex review found the original
    /// `== totalTestCount` check silently missed a real bundle shape —
    /// multiple test targets in one run, where one target's runner fails to
    /// install/launch (producing only a system-failure record) while a
    /// sibling target's tests actually execute and pass. `totalTestCount`
    /// there counts the sibling's passing tests too, so `systemFailures.count`
    /// (1) never equals it, the guard never fires, and the broken target's
    /// mutant fell through to `.failed` — a mutant credited as "caught" by a
    /// test that never ran. Comparing against `failures.count` instead asks
    /// the right question: are *all the failures actually recorded* explained
    /// by a broken runner, regardless of how many unrelated tests elsewhere in
    /// the same bundle happened to pass.
    func systemFailureOutcome(failures: [TestSummaryJSON.Failure], outcomeSummary: TestOutcomeSummary) -> Outcome? {
        let systemFailures = failures.filter(\.isSystemFailure)
        guard !systemFailures.isEmpty, systemFailures.count == failures.count else { return nil }
        return Outcome(
            status: .infrastructureFailure,
            summary: outcomeSummary,
            diagnosis: """
            The test runner failed to install or launch, so no test in the suite ran: \
            \(systemFailures[0].failureText)
            """
        )
    }

    /// The zero-work invariant for a narrowed selection: a run narrowed to
    /// an exact, pre-computed `selectedTests` count (never an unnarrowed
    /// whole-target list, which has no independently-known expected count
    /// to compare against) that reports *fewer* tests than that, with
    /// nothing else in `classify(summary:expectedTestCount:)` already
    /// explaining why — no crash, no timeout, no attributable failure, not
    /// even the "runner never started" system-failure shape — must not read
    /// as a pass. A target contributing nothing at all to the summary (the
    /// `TargetATests`/`TargetBTests` shape a real reproduction confirmed:
    /// see `XCResultAdapterTests`) leaves no failure record of its own kind
    /// for any check above to catch — only the missing count itself proves
    /// something did not run. `nil` `expectedTestCount` is a no-op:
    /// legitimate test-plan/filtering differences make a lower count
    /// unsuspicious for an unnarrowed run the way it is not for a narrowed
    /// one with an exact, known-in-advance expectation.
    func shortfallOutcome(
        summary: TestSummaryJSON,
        expectedTestCount: Int?,
        outcomeSummary: TestOutcomeSummary
    ) -> Outcome? {
        guard let expectedTestCount, summary.totalTestCount < expectedTestCount else { return nil }
        return Outcome(
            status: .infrastructureFailure,
            summary: outcomeSummary,
            diagnosis: """
            This run was narrowed to \(expectedTestCount) test(s), but the result bundle \
            records only \(summary.totalTestCount). Something in the selection did not run \
            and left no failure record explaining why, so the shortfall is not scored as a pass.
            """
        )
    }
}

// MARK: - Batch JSON

/// The same `xcresulttool get test-results summary` output as
/// `TestSummaryJSON`, but for a bundle produced from a `.xctestrun` v2
/// batch — Apple's schema calls this field out explicitly, and it is
/// present (non-empty) exactly when the bundle has more than one
/// `TestConfigurations` entry. Modelled separately from `TestSummaryJSON`
/// rather than folding `devicesAndConfigurations` into it: the two are read
/// through entirely different call sites (`classify` for one bundle,
/// `classifyBatch` for one bundle covering many configurations), and
/// keeping them apart means a decoding change for one can never silently
/// affect the other.
///
/// Deliberately has no `testFailures` field, unlike `TestSummaryJSON`: this
/// command's top-level `testFailures` array is batch-wide and unscoped to
/// any one configuration — real inspection showed a shared covering test
/// failing in one configuration produces exactly one entry here with no
/// configuration attached at all, so two sibling configurations that both
/// happen to include that identifier in their own narrowed selection are
/// indistinguishable by matching against it. Attribution instead comes
/// from `BatchTestNodesJSON`, whose `Test Plan Configuration` nodes are
/// scoped to one configuration by construction. Only `devicesAndConfigurations`
/// — each configuration's own real counts, not failure identities — is read
/// from this type now.
struct BatchTestSummaryJSON: Decodable {
    let devicesAndConfigurations: [DeviceConfiguration]?

    struct DeviceConfiguration: Decodable {
        let passedTests: Int
        let failedTests: Int
        let skippedTests: Int
        let expectedFailures: Int
        let testPlanConfiguration: Configuration

        struct Configuration: Decodable {
            let configurationName: String
        }
    }
}

/// `xcrun xcresulttool get test-results tests --compact`, for a batch
/// bundle covering more than one `Test Plan Configuration`. A tree —
/// `Test Plan` → `Unit test bundle` → `Test Suite` → `Test Case` →
/// `Test Plan Configuration` → `Failure Message` (node types confirmed
/// verbatim against real batch bundles) — rather than a flat list, which is
/// exactly what makes it safe to attribute a failure back to one
/// configuration: a `Test Plan Configuration` node only appears nested
/// under the one `Test Case` node it actually ran, so its own `result`
/// ("Passed", "Failed", "Skipped") can never be a neighbor's.
///
/// Modelled as its own type, distinct from whatever
/// `XcodeBuildAdapter.parseTestIdentifiers` reads the same command's output
/// into, for the same reason `BatchTestSummaryJSON` is kept apart from
/// `TestSummaryJSON`: different call site, different decoding needs, no
/// shared failure surface.
struct BatchTestNodesJSON: Decodable {
    let testNodes: [Node]

    /// One node in the tree. `children` is untyped-recursive (an array of
    /// this same type), which is why every field here is optional — a leaf
    /// `Failure Message` node has no `children` at all, and a `Test Suite`
    /// node has no `nodeIdentifier`.
    struct Node: Decodable {
        let name: String?
        let nodeType: String?
        let nodeIdentifier: String?
        let result: String?
        let children: [Node]?
        /// Only meaningful on a `Test Plan Configuration` node — confirmed
        /// present there against a real batch bundle (Gate 3 Phase H1
        /// spike): a native-timeout configuration's own duration lands
        /// exactly on the configured
        /// `-maximum-test-execution-time-allowance`, corroborating (never
        /// gating — see `TestSummaryJSON.Failure.isNativeTimeout`)
        /// `ownFailures`' structured-text classification.
        let durationInSeconds: Double?
    }
}

// MARK: - JSON

/// `xcrun xcresulttool get test-results summary --format json`, as Xcode 16+
/// emits it.
///
/// Only the fields this tool acts on are modelled, so an Xcode release that adds
/// keys cannot break decoding.
///
/// Two fields are deliberately typed against the observed output rather than
/// against Apple's published `--schema`: the schema declares
/// `devicesAndConfigurations` and `testFailures` as single objects, while the
/// tool actually emits arrays for both. The real output wins.
struct TestSummaryJSON: Decodable {
    /// `Passed`, `Failed`, `Skipped`, `Expected Failure` or `unknown`.
    let result: String
    let totalTestCount: Int
    let passedTests: Int
    let failedTests: Int
    let skippedTests: Int
    let expectedFailures: Int
    let testFailures: [Failure]?
    /// UNIX timestamps; absent on some bundles, so duration stays optional.
    let startTime: Double?
    let finishTime: Double?

    var durationSeconds: Double? {
        guard let startTime, let finishTime, finishTime >= startTime else { return nil }
        return finishTime - startTime
    }

    struct Failure: Decodable {
        let testName: String
        let targetName: String
        let failureText: String
        /// Absent on older bundles; `testName` is the fallback identity.
        let testIdentifierString: String?
        /// Only ever populated from the batch per-test hierarchy's own
        /// `Test Plan Configuration` node — `xcresulttool get test-results
        /// summary`'s flat `testFailures[]` (the single, unbatched
        /// classification path) carries no per-failure duration at all.
        /// `nil` there, never fetched with an extra process call just to
        /// fill it in: see `isNativeTimeout`'s doc comment for why it is
        /// corroboration only, never required.
        let durationInSeconds: Double?

        init(
            testName: String, targetName: String, failureText: String,
            testIdentifierString: String?, durationInSeconds: Double? = nil
        ) {
            self.testName = testName
            self.targetName = targetName
            self.failureText = failureText
            self.testIdentifierString = testIdentifierString
            self.durationInSeconds = durationInSeconds
        }

        /// Stable name for this test, preferring the fully-qualified form.
        var identifier: String {
            guard let testIdentifierString, !testIdentifierString.isEmpty else {
                return "\(targetName)/\(testName)"
            }
            return "\(targetName)/\(testIdentifierString)"
        }

        /// Whether the runner died rather than an assertion failing.
        ///
        /// A crash is reported as an ordinary failure with a non-zero count, so the
        /// only thing separating it from `XCTAssertEqual failed:` is how Xcode
        /// prefixes this field — it writes `Crash: xctest at <test>` for a signal or
        /// trap. This reads a structured field of the result bundle, not the
        /// runner's console output.
        var isCrash: Bool {
            failureText.hasPrefix("Crash:")
        }

        /// Whether XCTest's own native per-test execution-time allowance
        /// (`-maximum-test-execution-time-allowance`) cut this test off,
        /// rather than an assertion failing or the runner crashing.
        ///
        /// Confirmed against a real batch (Gate 3 Phase H1 spike,
        /// `XcodeBatchHangTimeoutSpikeAcceptanceTests`): the result
        /// bundle's `issueType` field does *not* distinguish this from an
        /// ordinary assertion failure — both read `"Uncategorized"` — but
        /// `failureText` always starts with this exact, fixed,
        /// Apple-authored sentence. Reads the same structured field
        /// `isCrash` does, the same way. `durationInSeconds` landing on
        /// the configured allowance is available as corroboration where
        /// the batch path already has it for free, but is never required:
        /// a native timeout must never be downgraded to an ordinary
        /// failure over a duration mismatch (rounding, clock skew, a
        /// caller that forgot to pass the allowance through) when the
        /// structured failure text already proves what happened.
        var isNativeTimeout: Bool {
            failureText.hasPrefix("Test exceeded execution time allowance")
        }

        /// Whether this is the test runner itself failing to install or launch,
        /// rather than any test in the suite failing.
        ///
        /// Xcode represents this as a synthetic pseudo-test named "<App> encountered
        /// an error" (or "xctest (<pid>) encountered an error" for a plain,
        /// non-app-hosted bundle) whose failure text is Xcode-authored — not
        /// project-specific. Read from a structured field of the result bundle, the
        /// same way `isCrash` is.
        ///
        /// Checks the synthetic pseudo-test *name*, not only one fixed `failureText`
        /// sentence: a real capture (a `__attribute__((constructor))`-forced crash
        /// during dyld image load, simulating a mutation that breaks a static/global
        /// initializer rather than causing a compile error) produced a completely
        /// different failureText — "Early unexpected exit, operation never finished
        /// bootstrapping..." — for the exact same synthetic-pseudo-test shape this
        /// property's own doc comment already described. Under the failureText-only
        /// check, that bundle fell through to `failedCountOutcome` and was
        /// classified `.failed`: a mutant credited as "caught" by a record that
        /// never ran a single real assertion. `testName` ending in "encountered an
        /// error" is the stable signal across both wordings — no real XCTest method
        /// identifier can contain a space, so this cannot collide with an actual
        /// test's own name. Both checks are kept (`||`, not replaced) so neither
        /// wording variant regresses the other.
        var isSystemFailure: Bool {
            failureText.hasPrefix("Failed to install or launch the test runner.")
                || testName.hasSuffix("encountered an error")
        }
    }
}
