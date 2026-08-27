import ArgumentParser
import Foundation
import MutationModel
import Reporting

/// Shows everything known about one mutant.
///
/// A score tells a developer nothing they can act on. A diff, the operator's
/// reasoning, the tests that ran, and the exact commands used do. This command
/// is where the tool's output stops being a number and becomes a change someone
/// can make.
struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show the full record for one mutation."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "The mutation ID, e.g. mut_a1b2c3d4e5f6a7b8.")
    var mutationID: String

    @Option(name: .long, help: "The plan containing the mutation.")
    var plan = "plan.json"

    @Option(name: .long, help: "A report to read the outcome from. Defaults to .mutantkit/report.json.")
    var report: String?

    /// P5: a structured, agent-consumable record — `AgentEvidenceReport`'s
    /// own doc comment has the full "why" — instead of the prose below.
    /// Every code path below still emits exactly one JSON document when
    /// this is set, including the not-found and skipped-at-planning-time
    /// cases: an agent parsing `--json` output must never be handed prose
    /// on an error path it did not anticipate.
    @Flag(name: .long, help: "Emit a structured JSON record for an agent to consume, instead of the report below.")
    var json = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: URL(fileURLWithPath: plan)))
        let id = MutationID(rawValue: mutationID)

        guard let point = loadedPlan.mutations.first(where: { $0.id == id }) else {
            try reportMissingMutation(id: id, loadedPlan: loadedPlan)
            return
        }

        let descriptor = loadedPlan.operators.first { $0.id == point.operatorID }
        let (loadedRun, result) = loadResult(for: id, root: root)

        if json {
            try printJSON(Self.agentEvidenceReport(
                point: point, descriptor: descriptor, result: result, toolchain: loadedRun?.toolchain, projectRoot: root
            ))
            return
        }

        print("""
        \(point.id)

        Location    \(point.displayLocation)
        Declaration \(point.enclosingDeclaration)
        Operator    \(point.operatorID) v\(point.operatorVersion)
        Confidence  \(point.confidence.rawValue)
        Mode        \(point.executionMode.rawValue)
        """)

        if let descriptor {
            print("\nWhat this operator does\n  \(descriptor.summary)")
            if !descriptor.faultEvidence.isEmpty {
                print("\nWhy this mutation is worth making")
                for evidence in descriptor.faultEvidence {
                    print("  \(evidence.replacingOccurrences(of: "\n", with: "\n  "))")
                }
            }
        }

        print("""

        The change
          - \(point.originalText)
          + \(point.replacementText.isEmpty ? "(removed)" : point.replacementText)

        Anchor
          bytes       \(point.utf8Range)
          syntax      \(point.expectedSyntaxKind)
          file hash   \(point.sourceFileHash)
          prefix      \(point.prefixTokenFingerprint)
          suffix      \(point.suffixTokenFingerprint)
          occurrence  \(point.occurrenceIndex)
        """)

        guard let result else {
            print("\nNo result yet. Run `mutantkit run`, or reproduce this mutant alone:")
            print("  mutantkit reproduce \(point.id)")
            return
        }

        print("""

        Outcome     \(result.outcome.displayName)
        Diagnosis   \(result.diagnosis)
        Duration    \(String(format: "%.2fs", result.durationSeconds))
        """)
        if result.origin != .fresh {
            print("Origin      \(originLabel(result.origin))")
        }

        if let summary = result.testSummary {
            print("Tests       \(summary.passed) passed, \(summary.failed) failed of \(summary.total)")
            if !summary.failingTests.isEmpty {
                print("Caught by")
                for test in summary.failingTests.prefix(10) {
                    print("  \(test)")
                }
            }
        }

        if let evidence = result.evidence {
            printEvidence(evidence)
        }

        print("Reproduce this mutant alone:\n  mutantkit reproduce \(point.id)")
    }

    private func printEvidence(_ evidence: MutationEvidence) {
        print("\nEvidence")
        print("  source before  \(evidence.sourceBeforeHash)")
        print("  source after   \(evidence.sourceAfterHash)")
        if let hash = evidence.buildProductHash {
            print("  build product  \(hash)")
        }
        switch evidence.applicationEvidence {
        case let .isolated(activation)?:
            let verdict = activation.provesActivation
                ? "proven active in the build product"
                : "NOT proven — the product is identical to the baseline's"
            print("  activation     \(verdict)")
        case let .schemata(observation)?:
            // The raw observation only — whether it actually proves
            // anything was already decided by `MutationVerdictVerifier
            // .verifySchemataChain` when this run's `Outcome` (above) was
            // produced; this display never re-derives that judgment.
            let receiptStatus = observation.buildReceipt != nil ? "resolved" : "unresolved"
            print("  activation     schemata run \(observation.expectation.runID.rawValue.uuidString)")
            print("                 build receipt \(receiptStatus), \(observation.transcript.records.count) transcript record(s)")
        case nil:
            break
        }
        if let build = evidence.buildCommand {
            print("\nBuild command\n  \(build.displayString)")
        }
        if let test = evidence.testCommand {
            print("\nTest command\n  \(test.displayString)")
        }
        if let artifact = evidence.resultArtifact {
            print("\nResult bundle\n  \(artifact)")
        }
        if let confirmation = evidence.crashConfirmation {
            printConfirmation(
                header: "Crash confirmation", reproducedLabel: "crashed again", reproduced: confirmation.crashedAgain,
                diagnosis: confirmation.diagnosis,
                buildCommand: confirmation.confirmingBuildCommand, testCommand: confirmation.confirmingTestCommand
            )
        }
        if let confirmation = evidence.timeoutConfirmation {
            printConfirmation(
                header: "Timeout confirmation", reproducedLabel: "timed out again", reproduced: confirmation.timedOutAgain,
                diagnosis: confirmation.diagnosis,
                buildCommand: confirmation.confirmingBuildCommand, testCommand: confirmation.confirmingTestCommand
            )
        }
        print("\nDiff\n\(evidence.sourceDiff)")
    }

    /// Shared rendering for `CrashConfirmation` and `TimeoutConfirmation` —
    /// identical shape (a header, whether the fresh rebuild reproduced the
    /// failure, a diagnosis, and the confirming build/test commands), only
    /// the labels differ.
    private func printConfirmation(
        header: String,
        reproducedLabel: String,
        reproduced: Bool,
        diagnosis: String,
        buildCommand: CommandRecord?,
        testCommand: CommandRecord?
    ) {
        print("\n\(header)")
        print("  \(reproducedLabel)  \(reproduced ? "yes — independently reproduced" : "no — reclassified, not a proven kill")")
        print("  \(diagnosis)")
        if let buildCommand {
            print("  confirming build command\n    \(buildCommand.displayString)")
        }
        if let testCommand {
            print("  confirming test command\n    \(testCommand.displayString)")
        }
    }

    private func originLabel(_ origin: ResultOrigin) -> String {
        switch origin {
        case .fresh:
            "freshly executed this run"
        case .checkpoint:
            "loaded from a checkpoint, not freshly executed this run"
        case .crossRunCache:
            "reused from the cross-run result cache, not rebuilt or retested this run"
        }
    }
}

/// P5: `--json` support, split from `InspectCommand`'s primary prose-report
/// body purely to stay under this project's `type_body_length` SwiftLint
/// limit, not because this belongs to a different feature.
extension InspectCommand {
    /// `--json` on the not-found path — a plan-agnostic, self-describing
    /// error object, never bare prose an agent's JSON parser would choke on.
    struct ErrorJSON: Codable {
        let error: String
    }

    /// `--json` on the skipped-at-planning-time path.
    struct SkippedMutationJSON: Codable {
        let mutantId: String
        let skipped: Bool
        let reason: String
        let detail: String?
    }

    /// Handles a mutation ID absent from `loadedPlan.mutations` — either it
    /// was skipped at planning time (reported, then `run()` returns
    /// normally) or it does not exist in this plan at all (reported, then
    /// this always throws). Split out of `run()` purely to keep that
    /// function under this project's `function_body_length`/
    /// `cyclomatic_complexity` limits — both `--json` and the not-found
    /// exit code are preserved exactly as `run()` itself used to produce
    /// them inline.
    func reportMissingMutation(id: MutationID, loadedPlan: MutationPlan) throws {
        if let skip = loadedPlan.skipped.first(where: { $0.id == id }) {
            if json {
                try printJSON(SkippedMutationJSON(mutantId: id.rawValue, skipped: true, reason: skip.reason.rawValue, detail: skip.detail))
                return
            }
            print("\(id) was skipped at planning time.")
            print("  reason: \(skip.reason.rawValue)")
            if let detail = skip.detail { print("  detail: \(detail)") }
            return
        }
        if json {
            try printJSON(ErrorJSON(error: "No mutation \(id) in \(plan)."))
        } else {
            print("No mutation \(id) in \(plan).")
        }
        throw ExitCode(MutantKitExit.operationalError)
    }

    /// Loads `.mutantkit/report.json` (or `--report`'s override) and this
    /// mutation's own result from it, or `(nil, nil)` for anything from "no
    /// report written yet" to "malformed JSON" — `inspect` is useful on a
    /// plan alone, before anything has been run, so this is a soft miss,
    /// never a thrown error.
    func loadResult(for id: MutationID, root: URL) -> (run: RunReport?, result: MutationResult?) {
        let reportURL = report.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".mutantkit/report.json")
        let loadedRun: RunReport? = (try? Data(contentsOf: reportURL))
            .flatMap { try? MutationPlan.decoder().decode(RunReport.self, from: $0) }
        return (loadedRun, loadedRun?.results.first { $0.id == id })
    }

    /// Canonical JSON, matching `JSONReporter`'s own convention (one
    /// spelling of "canonical JSON" for every artifact this tool writes),
    /// followed by a trailing newline so `--json` output composes cleanly
    /// with ordinary shell tooling (`| jq`, redirected to a file, etc.).
    func printJSON(_ value: some Encodable) throws {
        let data = try MutationPlan.encoder().encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    /// Builds the full `AgentEvidenceReport` for a mutation that exists in
    /// the plan — `result` is `nil` when no report has been loaded or this
    /// mutant has no entry in it yet (see `AgentEvidenceReport`'s own doc
    /// comment for why every field this produces is real data or `nil`,
    /// never inferred).
    static func agentEvidenceReport(
        point: MutationPoint, descriptor: OperatorDescriptor?, result: MutationResult?,
        toolchain: ToolchainFingerprint?, projectRoot: URL
    ) -> AgentEvidenceReport {
        AgentEvidenceReport(
            mutantId: point.id.rawValue,
            mutantOperator: AgentEvidenceReport.OperatorInfo(
                id: point.operatorID, version: point.operatorVersion,
                category: descriptor?.category ?? "unknown", summary: descriptor?.summary ?? "",
                confidence: point.confidence.rawValue
            ),
            source: AgentEvidenceReport.SourceInfo(
                file: point.file, line: point.line, column: point.column,
                original: point.originalText, replacement: point.replacementText,
                context: sourceContext(for: point, projectRoot: projectRoot),
                sourceFileHash: point.sourceFileHash
            ),
            verdict: result?.outcome.rawValue,
            verdictUnavailableReason: result == nil ? "noResultYet" : nil,
            diagnosis: result?.diagnosis,
            origin: result?.origin.rawValue,
            durationSeconds: result?.durationSeconds,
            tests: result?.testSummary.map {
                AgentEvidenceReport.TestsInfo(total: $0.total, passed: $0.passed, failed: $0.failed, caughtBy: $0.failingTests)
            },
            execution: AgentEvidenceReport.ExecutionInfo(
                mode: point.executionMode.rawValue,
                buildCommand: result?.evidence?.buildCommand.map { [$0.executable] + $0.arguments },
                testCommand: result?.evidence?.testCommand.map { [$0.executable] + $0.arguments },
                buildSDKIdentity: toolchain?.buildSDKIdentity, destinationRuntimeIdentity: toolchain?.destinationRuntimeIdentity
            ),
            evidence: result?.evidence.map(agentEvidenceInfo),
            reproduceCommand: "mutantkit reproduce \(point.id)",
            guidance: AgentEvidenceReport.GuidanceInfo()
        )
    }

    private static func agentEvidenceInfo(_ evidence: MutationEvidence) -> AgentEvidenceReport.EvidenceInfo {
        let kind: String
        let activationProven: Bool?
        switch evidence.applicationEvidence {
        case let .isolated(activation)?:
            kind = "isolated"
            activationProven = activation.provesActivation
        case .schemata?:
            kind = "schemata"
            // Whether the schemata chain actually proves anything was
            // already decided by `MutationVerdictVerifier
            // .verifySchemataChain` when this result's own outcome was
            // produced — not re-derived here, the same restraint
            // `InspectCommand.printEvidence`'s prose rendering already
            // takes for this exact case.
            activationProven = nil
        case nil:
            kind = "none"
            activationProven = nil
        }
        return AgentEvidenceReport.EvidenceInfo(
            kind: kind, activationProven: activationProven,
            sourceBeforeHash: evidence.sourceBeforeHash, sourceAfterHash: evidence.sourceAfterHash,
            buildProductHash: evidence.buildProductHash, diff: evidence.sourceDiff
        )
    }

    /// A few lines of source around the mutation, or `nil` — see
    /// `AgentEvidenceReport.SourceInfo.context`'s own doc comment for why
    /// this refuses to read a file that has moved on since the mutant was
    /// discovered, rather than showing possibly-wrong lines with no
    /// indication anything might be stale.
    private static func sourceContext(for point: MutationPoint, projectRoot: URL, radius: Int = 3) -> [String]? {
        let url = projectRoot.appendingPathComponent(point.file)
        guard let hash = try? ContentHash.ofFile(at: url), hash == point.sourceFileHash,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let lines = contents.components(separatedBy: .newlines)
        let zeroBasedLine = point.line - 1
        guard lines.indices.contains(zeroBasedLine) else { return nil }
        let start = max(0, zeroBasedLine - radius)
        let end = min(lines.count - 1, zeroBasedLine + radius)
        return Array(lines[start ... end])
    }
}
