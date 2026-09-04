import AppleBuildAdapters
import Foundation
import MutationModel
import MutationPlanner
import SwiftFrontend

/// Research-only, outcome-blind classification core for
/// `Research/adr-0008-validation/protocol.md`'s Protocol v3 addendum
/// (Corpus B calibration population selection rule). Separated from
/// `main.swift` so a test target can call it directly without going
/// through `ParsableCommand`/process argv.
///
/// Two layers, deliberately kept apart rather than collapsed into one
/// number:
///
/// - `lowererEligible` — a lowerer's own `analyze()`, informational only.
///   `analyze()` clearing a point individually is *not* proof it will
///   actually embed: `SchemataChunkPlanner.plan` can still batch-fail it
///   (a structural conflict only visible once every point in its chunk is
///   seen together — see `SchemataChunkPlannerBatchFailureRecoveryTests`
///   for the real incident that motivated that recovery path).
/// - `plannerEmbedded` — the authoritative signal: exactly
///   `result.schemataPlan.entries.filter(\.isEmbedded)`, computed by
///   actually running `SchemataChunkPlanner.plan` with the same registry/
///   target-resolution machinery `SchemataRunOrchestration`'s own
///   `classify(_:)` uses for a real formal run. Only this layer may define
///   a calibration population.
public enum EligibilityClassificationError: Error, CustomStringConvertible, Equatable {
    /// A candidate's (or the plan's) recorded source hash does not match
    /// the source actually on disk right now. A run-level failure, never
    /// downgraded to a per-mutant ineligible classification: a drifted
    /// source makes *every* downstream classification for that file
    /// unreliable, not just one candidate's, so silently continuing would
    /// misrepresent a data-integrity problem as an ordinary architectural
    /// exclusion.
    case sourceDrift(file: String, expectedHash: String, actualHash: String)
    /// A mutation's own file has no entry in the plan's `sourceFileHashes`
    /// map at all — `MutationPlan.decode`'s integrity check does not
    /// require full coverage there (an independent Codex review found the
    /// original drift check silently skipped verifying any file missing
    /// from that map, rather than treating the omission itself as
    /// suspect). Every candidate file must be checkable; one that is not
    /// is a run-level failure, the same as a file that fails the check.
    case missingSourceHash(file: String)
    /// `SwiftPMTargetResolver.resolveTargetInfo` — the same call the real
    /// formal run makes — failed. Surfaced loudly here, unlike
    /// `SchemataRunOrchestration.classify(_:)`'s own silent "degrade to
    /// isolated mode" behavior: this tool's whole purpose is diagnosis, so
    /// swallowing the failure and reporting an empty embedded set would be
    /// indistinguishable from "every candidate was legitimately
    /// ineligible" — exactly the ambiguity this tool exists to remove.
    case targetResolutionFailed(String)
    /// `SchemataChunkPlanner.plan` itself threw (missing source, missing
    /// target info, a non-positive chunk size, or a namespace collision).
    case chunkPlanningFailed(String)

    public var description: String {
        switch self {
        case let .sourceDrift(file, expected, actual):
            "source drift in \(file): plan recorded \(expected), current on-disk content hashes to \(actual) — " +
                "refusing to classify against a source the plan no longer describes"
        case let .missingSourceHash(file):
            "\(file) has a mutation candidate but no entry in the plan's sourceFileHashes — cannot verify it has not drifted"
        case let .targetResolutionFailed(detail):
            "target resolution failed: \(detail)"
        case let .chunkPlanningFailed(detail):
            "chunk planning failed: \(detail)"
        }
    }
}

public struct MutationClassification: Codable, Sendable, Equatable {
    public let mutationID: String
    public let file: String
    public let lowererEligible: Bool
    public let lowererIneligibleReason: String?
    public let plannerEmbedded: Bool
}

public struct EligibilityClassificationResult: Codable, Sendable {
    public let planPath: String
    public let operatorID: String
    public let totalCandidates: Int
    public let lowererEligibleCount: Int
    public let plannerEmbeddedCount: Int
    public let classifications: [MutationClassification]

    public var plannerEmbeddedMutationIDs: Set<String> {
        Set(classifications.filter(\.plannerEmbedded).map(\.mutationID))
    }
}

public enum EligibilityClassifier {
    /// Decodes `planData` via `MutationPlan.decode(from:)` — full schema-
    /// version and integrity validation, never a raw, permissive
    /// `JSONDecoder().decode(MutationPlan.self, from:)` that would let a
    /// structurally-invalid plan (duplicate/unstable `MutationID`s, an
    /// unsupported schema version) through silently — verifies every
    /// candidate's source has not drifted since discovery, then classifies
    /// every `operatorID`-matching candidate both ways described above.
    /// `resolveTargetInfo` defaults to the exact call the real formal run
    /// makes (`SwiftPMTargetResolver.resolveTargetInfo`, transitively via
    /// `SchemataRunOrchestration.classify(_:)`) — overridden only by tests,
    /// which inject a literal target map the same way
    /// `SchemataChunkPlannerTests` already does, rather than depending on a
    /// real SwiftPM checkout on disk.
    public static func classify(
        planData: Data,
        planPath: String,
        projectRoot: URL,
        operatorID: String,
        registry: SchemataLowererRegistry,
        maxChunkSize: Int = 200,
        resolveTargetInfo: @Sendable (URL) async throws -> [String: [SchemataTargetInfo]] = {
            try await SwiftPMTargetResolver.resolveTargetInfo(projectRoot: $0)
        }
    ) async throws -> EligibilityClassificationResult {
        let mutationPlan = try MutationPlan.decode(from: planData)
        try verifyNoSourceDrift(mutationPlan: mutationPlan, projectRoot: projectRoot)

        let candidateIDs = Set(mutationPlan.mutations.filter { $0.operatorID == operatorID }.map(\.id))

        // Candidate sources, then target resolution, then (only once both
        // have succeeded) `analyze()` — exactly matching
        // `SchemataRunOrchestration.classify(_:)`'s own real order (it too
        // reads candidate sources before resolving targets, but always
        // resolves targets before the planner — the only place `analyze()`
        // is ever invoked in the real formal run — runs at all). Found by
        // an independent Codex review to matter: a version that computed
        // the informational `lowererEligible` layer before attempting
        // target resolution could read as claiming `analyze()` runs even
        // when the real run's own target-resolution failure would prevent
        // it from ever being reached at all.
        var sources: [String: Data] = [:]
        try readSources(files: Set(mutationPlan.mutations.map(\.file)), projectRoot: projectRoot, into: &sources)

        let targetInfo: [String: [SchemataTargetInfo]]
        do {
            targetInfo = try await resolveTargetInfo(projectRoot)
        } catch {
            throw EligibilityClassificationError.targetResolutionFailed(String(describing: error))
        }
        let targetFiles = Set(targetInfo.keys).subtracting(sources.keys)
        try readSources(files: targetFiles, projectRoot: projectRoot, into: &sources)

        var sourceCache: [String: Data] = sources
        var lowererEligible: [MutationID: SchemataEligibility] = [:]
        for point in mutationPlan.mutations where point.operatorID == operatorID {
            guard let lowerer = registry.lowerer(forOperatorID: point.operatorID) else { continue }
            let source = try loadSource(file: point.file, projectRoot: projectRoot, cache: &sourceCache)
            lowererEligible[point.id] = lowerer.analyze(point, source: source)
        }

        // Backend metadata is pure record-keeping on `SchemataPlan` — it
        // plays no role in `classify`/`plan`'s own embedding decision, so a
        // labeled placeholder here does not affect `plannerEmbedded`.
        let backend = SchemataBackendInfo(
            backendID: "schemata-eligibility-classifier", backendVersion: 1,
            toolchainHash: "n/a (classification-only, not a real build)",
            buildArgumentsHash: mutationPlan.configurationHash
        )
        let planResult: SchemataChunkPlanResult
        do {
            planResult = try SchemataChunkPlanner.plan(
                mutationPlan: mutationPlan, registry: registry, sources: sources, targetInfo: targetInfo, backend: backend,
                maxChunkSize: maxChunkSize
            )
        } catch {
            throw EligibilityClassificationError.chunkPlanningFailed(String(describing: error))
        }
        let embeddedIDs = Set(planResult.schemataPlan.entries.filter(\.isEmbedded).map(\.mutationID))

        let mutationsByID = Dictionary(uniqueKeysWithValues: mutationPlan.mutations.map { ($0.id, $0) })
        let classifications = candidateIDs.sorted { $0.rawValue < $1.rawValue }.map { id -> MutationClassification in
            let eligibility = lowererEligible[id]
            let isEligible = eligibility?.isEligible ?? false
            let reason: String? = if case let .isolatedOnly(reason) = eligibility { String(describing: reason) } else { nil }
            return MutationClassification(
                mutationID: id.rawValue,
                file: mutationsByID[id]?.file ?? "",
                lowererEligible: isEligible,
                lowererIneligibleReason: reason,
                plannerEmbedded: embeddedIDs.contains(id)
            )
        }

        return EligibilityClassificationResult(
            planPath: planPath,
            operatorID: operatorID,
            totalCandidates: classifications.count,
            lowererEligibleCount: classifications.count { $0.lowererEligible },
            plannerEmbeddedCount: classifications.count { $0.plannerEmbedded },
            classifications: classifications
        )
    }

    /// Fails closed: two arms whose `plannerEmbedded` sets differ are never
    /// silently reconciled (union, intersection, "use whichever is
    /// smaller") — a real difference between the present/absent branches'
    /// planner-time classification would itself be a finding, not
    /// something to average away.
    public static func assertIdenticalAcrossArms(
        present: Set<String>, absent: Set<String>
    ) throws {
        guard present == absent else {
            let onlyPresent = present.subtracting(absent).sorted()
            let onlyAbsent = absent.subtracting(present).sorted()
            throw CrossArmMismatchError(onlyInPresent: onlyPresent, onlyInAbsent: onlyAbsent)
        }
    }

    public struct CrossArmMismatchError: Error, CustomStringConvertible, Equatable {
        public let onlyInPresent: [String]
        public let onlyInAbsent: [String]

        public var description: String {
            "plannerEmbedded sets differ across arms — only in present: \(onlyInPresent), only in absent: \(onlyInAbsent)"
        }
    }

    private static func verifyNoSourceDrift(mutationPlan: MutationPlan, projectRoot: URL) throws {
        // Every mutation candidate's own file must be checkable — a file
        // present in `mutations` but absent from `sourceFileHashes` (legal
        // under `MutationPlan.decode`'s integrity check, which does not
        // require full coverage there) would otherwise be silently
        // unverified rather than failing closed.
        let candidateFiles = Set(mutationPlan.mutations.map(\.file)).sorted()
        for file in candidateFiles where mutationPlan.sourceFileHashes[file] == nil {
            throw EligibilityClassificationError.missingSourceHash(file: file)
        }
        for (file, expectedHash) in mutationPlan.sourceFileHashes.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: projectRoot.appendingPathComponent(file))
            let actualHash = ContentHash.of(data)
            guard actualHash == expectedHash else {
                throw EligibilityClassificationError.sourceDrift(file: file, expectedHash: expectedHash, actualHash: actualHash)
            }
        }
    }

    private static func loadSource(file: String, projectRoot: URL, cache: inout [String: Data]) throws -> Data {
        if let cached = cache[file] { return cached }
        let data = try Data(contentsOf: projectRoot.appendingPathComponent(file))
        cache[file] = data
        return data
    }

    private static func readSources(files: Set<String>, projectRoot: URL, into sources: inout [String: Data]) throws {
        for file in files where sources[file] == nil {
            sources[file] = try Data(contentsOf: projectRoot.appendingPathComponent(file))
        }
    }
}

/// Blocks the calling thread until `operation` completes — a small bridge
/// for callers (the synchronous CLI entry point in `main.swift`) that need
/// an `async` result without adopting `AsyncParsableCommand` themselves
/// (see `main.swift`'s own doc comment for why that proved unreliable to
/// invoke correctly from a `main.swift` top-level statement in practice).
public func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        do {
            box.result = .success(try await operation())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
