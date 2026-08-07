import ArgumentParser
import Foundation
import MutationModel

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

    func run() async throws {
        let root = common.resolvedProjectRoot
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: URL(fileURLWithPath: plan)))
        let id = MutationID(rawValue: mutationID)

        guard let point = loadedPlan.mutations.first(where: { $0.id == id }) else {
            if let skip = loadedPlan.skipped.first(where: { $0.id == id }) {
                print("\(id) was skipped at planning time.")
                print("  reason: \(skip.reason.rawValue)")
                if let detail = skip.detail { print("  detail: \(detail)") }
                return
            }
            print("No mutation \(id) in \(plan).")
            throw ExitCode(MutantKitExit.operationalError)
        }

        let descriptor = loadedPlan.operators.first { $0.id == point.operatorID }

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

        // The result is optional: `inspect` is useful on a plan alone, before
        // anything has been run.
        let reportURL = report.map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".mutantkit/report.json")

        guard let data = try? Data(contentsOf: reportURL),
              let run = try? MutationPlan.decoder().decode(RunReport.self, from: data),
              let result = run.results.first(where: { $0.id == id })
        else {
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
