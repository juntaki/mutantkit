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

    /// v0.5 Stable Contracts: `verify` was the one "check something and
    /// report" command (alongside `gate`/`doctor`/`inspect`) with no
    /// machine-readable output at all — every other one already had
    /// `--json`. Deliberately narrow: one new `Codable` type
    /// (`VerifyResult`) and this flag, not a rewrite of the prose logic
    /// below, which is unchanged.
    @Flag(name: .long, help: "Emit the verification result as JSON instead of the text report below.")
    var json = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        let loadedPlan = try Self.decode(planPath: plan, json: json)

        if !json {
            print("Verifying plan \(loadedPlan.planID) — \(loadedPlan.mutations.count) mutation(s)\n")
        }

        let compatibility = await Self.resolveCompatibility(of: loadedPlan, root: root, configPath: common.configPath)
        if !json {
            Self.printCompatibility(compatibility)
        }

        let idViolations = IntegrityChecker.validatePlan(loadedPlan)
        if !json {
            if idViolations.isEmpty {
                print("✓ Mutation IDs  every ID recomputes from its own components")
            } else {
                print("✗ Mutation IDs  \(idViolations.count) problem(s)")
                for violation in idViolations {
                    print("  └─ \(violation.detail)")
                }
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
            } else if verbose, !json {
                print("  ✓ \(point.id) \(point.displayLocation) \(point.operatorID)")
            }
        }

        let verified = loadedPlan.mutations.count - rejected.count - unreadable.count
        if !json {
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
        }

        let valid = idViolations.isEmpty && rejected.isEmpty && unreadable.isEmpty

        if json {
            try JSONOutput.emit(VerifyResult(
                planID: loadedPlan.planID,
                mutationCount: loadedPlan.mutations.count,
                valid: valid,
                idViolations: idViolations.map(\.detail),
                missingFiles: Set(unreadable).sorted(),
                anchorViolations: rejected.map {
                    VerifyResult.AnchorViolation(mutationID: $0.0.id.rawValue, location: $0.0.displayLocation, diagnosis: $0.1.diagnosis)
                },
                compatibility: compatibility.jsonValue
            ))
        }

        guard valid else {
            if !json {
                print("""

                This plan is stale. Anchors are never relocated by guesswork — a mismatched \
                mutation would be reported `notApplied` rather than applied somewhere else. \
                Re-run `mutantkit plan` to plan against the current source.
                """)
            }
            throw ExitCode(MutantKitExit.integrityFailure)
        }

        if !json {
            print("\nPlan is valid and current.")
        }
    }

    /// `--json` needs the same "one JSON document on every path" discipline
    /// every other `--json` command's own report-decode failure already
    /// has (see `GateCommand.decode`) — a missing/malformed plan file must
    /// not fall through to the prose-only `MutantKitExit.onFailure` path
    /// when `--json` was requested.
    private static func decode(planPath: String, json: Bool) throws -> MutationPlan {
        do {
            return try MutationPlan.decode(from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        } catch {
            guard json else {
                return try MutantKitExit.onFailure { throw error }
            }
            try JSONOutput.emitError(
                code: "planUnreadable",
                message: "Could not read the plan at \"\(planPath)\" as a MutantKit JSON plan: \(error)",
                remedy: "Check --plan points at a real plan.json written by `mutantkit plan`."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }
    }

    // Best-effort and supplementary to the anchor check above, which is this
    // command's real job: a missing config file just means there is nothing
    // to compare the plan's recorded configuration against yet (e.g. `verify`
    // run right after `plan`, before `mutantkit.yml` exists), not a reason to
    // fail. A malformed one is still surfaced — silently skipping it would
    // hide a real problem, not a nonexistent one.
    private static func resolveCompatibility(
        of loadedPlan: MutationPlan, root: URL, configPath: String?
    ) async -> VerifyCompatibilityStatus {
        do {
            let configuration = try ConfigurationLoader.load(explicitPath: configPath, projectRoot: root)
            let toolchainProbe = await ToolchainProbe.fingerprint(workingDirectory: root)
            return .resolved(compatibilityOutcome(plan: loadedPlan, configuration: configuration, toolchainProbe: toolchainProbe))
        } catch let error as ConfigurationError {
            if case .notFound = error {
                return .notApplicable
            }
            return .checkFailed(error.description)
        } catch {
            return .checkFailed("\(error)")
        }
    }

    private static func printCompatibility(_ status: VerifyCompatibilityStatus) {
        switch status {
        case let .resolved(outcome):
            switch outcome {
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
        case .notApplicable:
            () // Nothing to compare against yet — not a failure, nothing to print.
        case let .checkFailed(description):
            print("! Compatibility could not be checked: \(description)")
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

    /// Whether/how `resolveCompatibility` actually resolved a verdict —
    /// wraps `PlanCompatibilityOutcome` with the two states that only ever
    /// arise from *checking* it (no config found yet, or the check itself
    /// threw), which `PlanCompatibilityOutcome` itself deliberately has no
    /// cases for (it is pinned directly by `VerifyCommandCompatibilityTests`
    /// against hand-built `ToolchainProbeResult` values, and adding
    /// I/O-only cases there would be out of place).
    enum VerifyCompatibilityStatus {
        case resolved(PlanCompatibilityOutcome)
        case notApplicable
        case checkFailed(String)

        var jsonValue: String {
            switch self {
            case let .resolved(outcome):
                switch outcome {
                case .match: "match"
                case .differences: "differences"
                case .unproven: "unproven"
                }
            case .notApplicable: "notApplicable"
            case .checkFailed: "checkFailed"
            }
        }
    }
}

/// `mutantkit verify --json`. Deliberately compact: a plan's own IDs/anchors
/// are already fully proven or refused by `MutationPlan.decode`/
/// `IntegrityChecker`/`SourceAnchorVerifier` before this is ever built — this
/// is a report of that verdict, not a second place any of it is decided.
struct VerifyResult: Codable {
    struct AnchorViolation: Codable {
        let mutationID: String
        let location: String
        let diagnosis: String
    }

    let schemaVersion: Int
    let planID: String
    let mutationCount: Int
    let valid: Bool
    let idViolations: [String]
    let missingFiles: [String]
    let anchorViolations: [AnchorViolation]
    /// One of: "match", "differences", "unproven" (toolchain probe
    /// incomplete), "notApplicable" (no config to compare against yet), or
    /// "checkFailed" (compatibility could not be checked at all) — see
    /// `VerifyCommand.VerifyCompatibilityStatus`. Deliberately a bare
    /// string, not the full difference/issue list: the compatibility
    /// *issues* themselves are `ConfigurationIssue`, already returned in
    /// full by `mutantkit config --json`, and duplicating that shape here
    /// would be a second place for the same list to drift.
    let compatibility: String

    init(
        planID: String, mutationCount: Int, valid: Bool, idViolations: [String],
        missingFiles: [String], anchorViolations: [AnchorViolation], compatibility: String
    ) {
        schemaVersion = SchemaVersion.verifyResult
        self.planID = planID
        self.mutationCount = mutationCount
        self.valid = valid
        self.idViolations = idViolations
        self.missingFiles = missingFiles
        self.anchorViolations = anchorViolations
        self.compatibility = compatibility
    }
}
