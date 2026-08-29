import ArgumentParser
import Foundation
import MutationModel
import SwiftFrontend

/// Checks a plan against the source it claims to describe, without building.
///
/// Two independent failures are worth catching before an hour of builds: a plan
/// whose IDs do not recompute from their own components (it was hand-edited, or
/// written by an incompatible version), and a plan whose anchors no longer match
/// the tree (the source moved on since planning). Both are silent at run time
/// unless something looks for them.
struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check a plan's IDs and anchors against the current source."
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "The plan to verify.")
    var plan = "plan.json"

    @Flag(name: .long, help: "Print every mutation, not only the failures.")
    var verbose = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: URL(fileURLWithPath: plan)))

        print("Verifying plan \(loadedPlan.planID) — \(loadedPlan.mutations.count) mutation(s)\n")

        await printCompatibility(of: loadedPlan, root: root)

        let idViolations = IntegrityChecker.validatePlan(loadedPlan)
        if idViolations.isEmpty {
            print("✓ Mutation IDs  every ID recomputes from its own components")
        } else {
            print("✗ Mutation IDs  \(idViolations.count) problem(s)")
            for violation in idViolations {
                print("  └─ \(violation.detail)")
            }
        }

        // Read each file once: a plan typically holds many mutations per file,
        // and re-reading per mutation would make verify slower than it needs to be.
        var sources: [String: Data] = [:]
        var rejected: [(MutationPoint, AnchorVerification)] = []
        var unreadable: [String] = []

        for point in loadedPlan.mutations {
            let data: Data
            if let cached = sources[point.file] {
                data = cached
            } else {
                guard let read = try? Data(contentsOf: root.appendingPathComponent(point.file)) else {
                    unreadable.append(point.file)
                    sources[point.file] = Data()
                    continue
                }
                sources[point.file] = read
                data = read
            }

            let verification = SourceAnchorVerifier.verify(point, against: data, depth: .full)
            if !verification.isValid {
                rejected.append((point, verification))
            } else if verbose {
                print("  ✓ \(point.id) \(point.displayLocation) \(point.operatorID)")
            }
        }

        let verified = loadedPlan.mutations.count - rejected.count - unreadable.count
        if rejected.isEmpty, unreadable.isEmpty {
            print("✓ Anchors       all \(verified) anchor(s) match the current source")
        } else {
            print("✗ Anchors       \(verified) of \(loadedPlan.mutations.count) match")
            for file in Set(unreadable).sorted() {
                print("  └─ missing file: \(file)")
            }
            for (point, verification) in rejected.prefix(20) {
                print("  └─ \(point.displayLocation) (\(point.id))")
                print("     \(verification.diagnosis)")
            }
            if rejected.count > 20 {
                print("  └─ …and \(rejected.count - 20) more")
            }
        }

        guard idViolations.isEmpty, rejected.isEmpty, unreadable.isEmpty else {
            print("""

            This plan is stale. Anchors are never relocated by guesswork — a mismatched \
            mutation would be reported `notApplied` rather than applied somewhere else. \
            Re-run `mutantkit plan` to plan against the current source.
            """)
            throw ExitCode(MutantKitExit.integrityFailure)
        }

        print("\nPlan is valid and current.")
    }

    // Best-effort and supplementary to the anchor check above, which is this
    // command's real job: a missing config file just means there is nothing
    // to compare the plan's recorded configuration against yet (e.g. `verify`
    // run right after `plan`, before `mutantkit.yml` exists), not a reason to
    // fail. A malformed one is still surfaced — silently skipping it would
    // hide a real problem, not a nonexistent one.
    private func printCompatibility(of loadedPlan: MutationPlan, root: URL) async {
        do {
            let configuration = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
            let toolchainProbe = await ToolchainProbe.fingerprint(workingDirectory: root)
            switch Self.compatibilityOutcome(plan: loadedPlan, configuration: configuration, toolchainProbe: toolchainProbe) {
            case .match:
                print("✓ Compatibility plan's toolchain and configuration hash match this environment")
            case let .differences(issues):
                print("! Compatibility \(issues.count) difference(s) from this environment")
                for issue in issues { print("  └─ \(issue.message)") }
            case .unproven:
                // Never a "✓ ... match": either side's evidence being
                // unproven could just as easily hide a real difference as
                // paper over one — printing a match here would be a
                // compatibility verdict built on evidence that was never
                // actually gathered, against this project's own "unknown
                // evidence never becomes a verdict" principle.
                print("! Compatibility could not be proven this run")
                print("  └─ this run's toolchain probe was incomplete (a subprocess failed, timed out, "
                    + "or produced no parseable output) — re-run `mutantkit verify` to get a trustworthy comparison")
            }
        } catch let error as ConfigurationError {
            if case .notFound = error {
                // Nothing to compare against yet — not a failure.
            } else {
                print("! Compatibility could not be checked: \(error.description)")
            }
        } catch {
            print("! Compatibility could not be checked: \(error)")
        }
        print("")
    }
}

extension VerifyCommand {
    /// Whether `loadedPlan`'s recorded toolchain/configuration identity
    /// matches this run's — `.unproven`, never `.match`, when
    /// `toolchainProbe`'s own evidence was incomplete: two independently
    /// incomplete probes can both collapse to the same "unknown" toolchain
    /// field, which would otherwise read as a match built on nothing. Split
    /// out from `printCompatibility` purely so this decision can be pinned
    /// by a direct, no-filesystem unit test (`VerifyCommandCompatibilityTests`)
    /// that hand-constructs `ToolchainProbeResult` values, mirroring
    /// `ToolchainProbe.combinedIdentityEvidenceComplete`'s own reason for
    /// existing as a standalone function.
    enum PlanCompatibilityOutcome: Equatable {
        case match
        case differences([ConfigurationIssue])
        case unproven
    }

    static func compatibilityOutcome(
        plan: MutationPlan, configuration: Configuration, toolchainProbe: ToolchainProbeResult
    ) -> PlanCompatibilityOutcome {
        guard toolchainProbe.identityEvidenceComplete else { return .unproven }
        let issues = PlanCompatibilityValidator.check(plan, against: configuration, toolchain: toolchainProbe.fingerprint)
        return issues.isEmpty ? .match : .differences(issues)
    }
}
