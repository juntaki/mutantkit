import ArgumentParser
import Foundation
import MutationModel
import MutationPlanner

/// Research-only, execution-vehicle tool for
/// `Research/budget-selection-v2/evaluation-protocol.md` §4.1 (revision 7):
/// given a full "allocation universe" plan (the complete discovered pool a
/// corpus's allocators/selectors saw) and a pre-computed, frozen "outcome
/// execution universe" `U'` — the exact `MutationID` subset any pre-registered
/// selection in the protocol can ever consume — derives a smaller, standalone
/// plan scoped to exactly `U'`, through `MutationPlan`/`PlanSharding`'s own
/// model-level decode/encode APIs. Never hand-edits plan JSON as text.
///
/// This is exactly the "plan-file post-processing step that removes every
/// non-`U` entry before `mutantkit run` sees it" §4.1's "Implementation
/// prerequisite" paragraph calls out as a CLI gap that must be closed before
/// real execution can be scoped. It changes nothing about `U`, `N`, the
/// selectors, seeds, weights, budgets, metrics, or thresholds — it only
/// derives a runnable execution vehicle for a `U'` computed elsewhere.
///
/// Not `@main`: this file is `main.swift`, which is itself the top-level
/// entry point (a `@main` attribute in a file named `main.swift` is a
/// compiler error) — `PlanSubsetDerivationCLI.main()` is invoked as an
/// ordinary top-level statement at the bottom of this file instead.
struct PlanSubsetDerivationCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan-subset-derivation",
        abstract: """
        Derives a standalone MutationPlan scoped to an explicit MutationID subset (§4.1's \
        outcome execution universe U), via MutationPlan/PlanSharding's own model APIs.
        """
    )

    @Option(help: "Path to the parent (allocation-universe) plan.json.")
    var parentPlan: String

    @Option(help: "Path to a text file with one MutationID per line — the frozen U' set.")
    var mutationIdsFile: String

    @Option(help: "Expected parent mutation count (fails closed if the parent plan does not match).")
    var expectedParentCount: Int

    @Option(help: "Expected U' member count (fails closed if the id file does not match).")
    var expectedSubsetCount: Int

    @Option(help: "Where to write the derived, U'-scoped plan.json.")
    var outputPlan: String

    @Option(help: "Where to write the machine-readable provenance manifest (JSON).")
    var outputProvenance: String

    @Option(help: "The evaluation-protocol.md revision label this derivation is scoped under (e.g. \"revision-7\").")
    var evaluationProtocolRevision: String

    @Option(help: "The evaluation-protocol.md commit SHA this derivation is scoped under.")
    var revisionCommit: String

    func run() throws {
        // 0. Refuse any aliasing between distinct declared paths before
        //    touching disk. Without this, e.g. `--output-plan` equal to
        //    `--parent-plan` would let a later write silently clobber the
        //    read-only parent input this whole tool exists to never mutate.
        let declaredPaths: [(flag: String, path: String)] = [
            ("--parent-plan", parentPlan),
            ("--mutation-ids-file", mutationIdsFile),
            ("--output-plan", outputPlan),
            ("--output-provenance", outputProvenance)
        ]
        var byCanonicalPath: [String: String] = [:]
        for (flag, path) in declaredPaths {
            let canonical = Self.canonicalKey(for: path)
            if let colliding = byCanonicalPath[canonical] {
                throw DerivationError.aliasedPaths(colliding, flag)
            }
            byCanonicalPath[canonical] = flag
        }

        // 1. Load and verify the parent plan through MutationPlan.decode —
        //    never raw JSON parsing. decode() already enforces schema version
        //    and IntegrityChecker.validatePlan's structural invariants
        //    (duplicate/unstable MutationIDs, budgetInclusionReasons
        //    one-to-one), so a parent plan that fails those never gets this far.
        let parentData = try Data(contentsOf: URL(fileURLWithPath: parentPlan))
        let parent: MutationPlan
        do {
            parent = try MutationPlan.decode(from: parentData)
        } catch {
            throw DerivationError.parentPlanInvalid(String(describing: error))
        }

        guard parent.mutations.count == expectedParentCount else {
            throw DerivationError.parentCountMismatch(
                expected: expectedParentCount, found: parent.mutations.count
            )
        }

        // 2. Load and verify U': exactly the expected count, no duplicates.
        let rawLines = try String(contentsOf: URL(fileURLWithPath: mutationIdsFile), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var duplicates: [String] = []
        for raw in rawLines where !seen.insert(raw).inserted {
            duplicates.append(raw)
        }
        guard duplicates.isEmpty else {
            throw DerivationError.duplicateSubsetIDs(duplicates.sorted())
        }
        guard rawLines.count == expectedSubsetCount else {
            throw DerivationError.subsetCountMismatch(expected: expectedSubsetCount, found: rawLines.count)
        }

        let subsetIDs = rawLines.map { MutationID(rawValue: $0) }

        // U' ⊆ parent's MutationID set — checked explicitly here (in addition
        // to PlanSharding.subset's own check below) so a missing-ID failure
        // is reported before any plan construction is attempted, with exactly
        // which IDs are missing.
        let parentIDs = Set(parent.mutations.map(\.id))
        let missing = subsetIDs.filter { !parentIDs.contains($0) }.map(\.rawValue).sorted()
        guard missing.isEmpty else {
            throw DerivationError.subsetNotSubsetOfParent(missing)
        }

        let parentIdentity = parent.workUnitID

        // 3. Derive the subset plan entirely through PlanSharding's model-level
        //    subset construction (same code path `shard` uses to build shard
        //    plans) — never an independent re-implementation of plan format.
        let derived = try PlanSharding.subset(of: parent, mutationIDs: subsetIDs)

        // Verify the derived plan is genuinely standalone-runnable: re-encode
        // and re-decode it through MutationPlan's own APIs, then check exact
        // membership.
        let derivedData = try derived.encoded()
        let redecoded = try MutationPlan.decode(from: derivedData)
        guard redecoded.mutations.count == expectedSubsetCount else {
            throw DerivationError.derivedCountMismatch(
                expected: expectedSubsetCount, found: redecoded.mutations.count
            )
        }
        let redecodedIDs = Set(redecoded.mutations.map(\.id.rawValue))
        guard redecodedIDs == Set(rawLines) else {
            throw DerivationError.derivedMembershipMismatch
        }

        try derivedData.write(to: URL(fileURLWithPath: outputPlan))

        // 4. Write the provenance manifest.
        let sortedSubsetIDs = rawLines.sorted()
        let subsetSetHash = ContentHash.of(sortedSubsetIDs.joined(separator: "\u{1F}"))
        let excludedCount = parent.mutations.count - subsetIDs.count

        let manifest = ProvenanceManifest(
            parentPlanID: parent.planID,
            parentPlanIdentity: parentIdentity,
            parentMutationCount: parent.mutations.count,
            evaluationProtocolRevision: evaluationProtocolRevision,
            evaluationProtocolCommit: revisionCommit,
            subsetMemberCount: subsetIDs.count,
            subsetMutationIDSetHash: subsetSetHash,
            derivedPlanID: redecoded.planID,
            derivedPlanIdentity: redecoded.workUnitID,
            excludedMutationCount: excludedCount,
            statement: """
            Allocation and synthetic selections (BudgetSelectorV2.allocate/.allocateCounts, \
            BudgetSelector.selectByOperatorSubtype, and every §5.3 synthetic weight-vector round) \
            were computed over the original N=\(parent.mutations.count) allocation universe \
            described by the parent plan referenced above. This derived plan is execution-only: \
            it scopes real `mutantkit run` to exactly the pre-registered outcome execution \
            universe U' (§4.1) and is never an input to any allocator or synthetic-selection \
            computation.
            """
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: URL(fileURLWithPath: outputProvenance))

        print("Parent plan: \(parentPlan)")
        print("  planID: \(parent.planID)")
        print("  identity (workUnitID): \(parentIdentity)")
        print("  mutations: \(parent.mutations.count)")
        print("U' subset: \(mutationIdsFile)")
        print("  members: \(subsetIDs.count)")
        print("  excluded: \(excludedCount)")
        print("Derived plan written: \(outputPlan)")
        print("  planID: \(redecoded.planID)")
        print("  identity (workUnitID): \(redecoded.workUnitID)")
        print("  decoded mutation count: \(redecoded.mutations.count)")
        print("Provenance manifest written: \(outputProvenance)")
    }

    /// Identifies what file a path actually refers to, robustly enough that
    /// two differently-spelled paths naming the same file are caught as a
    /// collision by the aliasing guard above.
    ///
    /// `URL.standardizedFileURL` alone only normalizes `.`/`..` syntax — it
    /// does not resolve symlinks, so a symlink (or a symlinked ancestor
    /// directory) pointing at the parent plan would sail past a purely
    /// syntactic check and still let an output write clobber it. For a path
    /// that already exists on disk as a regular file, `stat`'s device+inode
    /// pair is the actual filesystem identity (this also catches hard links,
    /// which have no distinguishing path form at all).
    ///
    /// A path whose *final* component is itself a symlink needs `lstat`, not
    /// `stat`: `stat` follows symlinks and simply fails for a dangling one,
    /// which would make this function fall through to the not-yet-existing
    /// branch and treat the dangling link's own path as the identity —
    /// exactly wrong, since a dangling symlink still names a real write
    /// target once something creates it, and two dangling symlinks (or a
    /// dangling symlink and its literal target path) pointing at the same
    /// place must collide. So the symlink chain is followed manually here
    /// (bounded, to refuse an adversarial symlink loop) until it reaches
    /// either an existing non-symlink file (inode identity) or a target path
    /// that does not exist at all — only then does the not-yet-existing,
    /// ancestor-directory-symlink-resolving fallback apply, to the fully
    /// resolved target rather than to the original (possibly symlink) path.
    ///
    /// Deliberately does not attempt to close the TOCTOU gap between this
    /// check and the later write (another process replacing a path with a
    /// symlink/hard link in that window): this is a single-operator,
    /// manually-invoked local research tool with no concurrent or
    /// adversarial actor in its threat model, and hardening against that
    /// would mean routing every write through already-open file descriptors
    /// instead of paths — a materially larger, more speculative change than
    /// this tool's actual job (deriving §4.1's execution-scoped plan)
    /// warrants. Recorded here rather than silently ignored.
    private static func canonicalKey(for path: String) -> String {
        var resolved = URL(fileURLWithPath: path).standardizedFileURL
        var symlinkHops = 0
        while symlinkHops < 40 {
            var linkStatus = stat()
            guard lstat(resolved.path, &linkStatus) == 0 else {
                // Nothing at all here yet (not even a dangling symlink) — the
                // not-yet-existing fallback below applies to `resolved` as-is.
                break
            }
            guard linkStatus.st_mode & S_IFMT == S_IFLNK else {
                // An existing non-symlink file/directory: device+inode is its
                // real, hard-link-proof identity.
                return "inode:\(linkStatus.st_dev):\(linkStatus.st_ino)"
            }
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path) else {
                break
            }
            symlinkHops += 1
            resolved = URL(fileURLWithPath: target, relativeTo: resolved.deletingLastPathComponent())
                .standardizedFileURL
        }

        var url = resolved
        var trailingComponents: [String] = []
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
            trailingComponents.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        let resolvedBase = url.resolvingSymlinksInPath()
        let finalURL = trailingComponents.reduce(resolvedBase) { $0.appendingPathComponent($1) }
        return "path:" + finalURL.path
    }
}

struct ProvenanceManifest: Codable {
    let parentPlanID: String
    let parentPlanIdentity: String
    let parentMutationCount: Int
    let evaluationProtocolRevision: String
    let evaluationProtocolCommit: String
    let subsetMemberCount: Int
    let subsetMutationIDSetHash: String
    let derivedPlanID: String
    let derivedPlanIdentity: String
    let excludedMutationCount: Int
    let statement: String
}

enum DerivationError: Error, CustomStringConvertible {
    /// Two distinct CLI path options resolved to the same file. Refused
    /// unconditionally rather than only when it happens to be the parent
    /// plan: any aliasing means one write silently clobbers another
    /// declared file, which is never intended for a tool whose entire job
    /// is to leave the parent plan untouched.
    case aliasedPaths(String, String)
    case parentPlanInvalid(String)
    case parentCountMismatch(expected: Int, found: Int)
    case duplicateSubsetIDs([String])
    case subsetCountMismatch(expected: Int, found: Int)
    case subsetNotSubsetOfParent([String])
    case derivedCountMismatch(expected: Int, found: Int)
    case derivedMembershipMismatch

    var description: String {
        switch self {
        case let .aliasedPaths(first, second):
            "\(first) and \(second) resolve to the same file; every declared path must be distinct."
        case let .parentPlanInvalid(detail):
            "Parent plan failed to decode/validate through MutationPlan.decode: \(detail)"
        case let .parentCountMismatch(expected, found):
            "Parent plan has \(found) mutation(s), expected exactly \(expected)."
        case let .duplicateSubsetIDs(ids):
            "U' MutationID file has duplicate entries: \(ids.joined(separator: ", "))"
        case let .subsetCountMismatch(expected, found):
            "U' MutationID file has \(found) entries, expected exactly \(expected)."
        case let .subsetNotSubsetOfParent(ids):
            """
            \(ids.count) U' MutationID(s) are not present in the parent plan (U' ⊄ parent): \
            \(ids.joined(separator: ", "))
            """
        case let .derivedCountMismatch(expected, found):
            "Derived plan re-decoded with \(found) mutation(s), expected exactly \(expected)."
        case .derivedMembershipMismatch:
            "Derived plan's re-decoded MutationID set does not exactly equal the requested U' set."
        }
    }
}

PlanSubsetDerivationCLI.main()
