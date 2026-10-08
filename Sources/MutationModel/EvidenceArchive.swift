import Foundation

/// The opt-in `evidence` section of the configuration.
///
/// When `archive` is on, a run writes the raw `MutationObservations` behind
/// each result it evaluated to `.mutantkit/evidence/<run-id>/`, so a later
/// `mutantkit verify-run` can re-run `MutationVerdictVerifier` offline instead
/// of trusting the report's own outcomes. Off by default: the archive can be
/// large and holds test output, which a project may not want on disk.
/// Writing it never changes a verdict or a score.
public struct EvidenceSettings: Codable, Sendable, Hashable {
    public var archive: Bool
    /// How many archives to keep under `.mutantkit/evidence/` once a run has
    /// written its own: the newest `keep`, the run's own included. `nil`
    /// (the default) keeps every archive. Only directories that look like
    /// archives are ever removed.
    public var keep: Int?

    public init(archive: Bool = false, keep: Int? = nil) {
        self.archive = archive
        self.keep = keep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archive = try container.decodeIfPresent(Bool.self, forKey: .archive) ?? false
        keep = try container.decodeIfPresent(Int.self, forKey: .keep)
    }
}

/// What a report records about the evidence archive written for its run: the
/// run identity and a hash of the archive's manifest. A hash narrows what an
/// edited archive can pass as; it is not a signature.
public struct EvidenceArchiveReference: Codable, Sendable, Hashable {
    public let runID: String
    public let manifestHash: String
    public let entryCount: Int

    public init(runID: String, manifestHash: String, entryCount: Int) {
        self.runID = runID
        self.manifestHash = manifestHash
        self.entryCount = entryCount
    }
}

/// `manifest.json` of one archive: which run it belongs to, the confirmation
/// policy and versions the run used, and the content hash of every
/// observation file.
public struct EvidenceArchiveManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let mutationID: String
        /// A plain file name under `observations/`.
        public let file: String
        public let hash: String

        public init(mutationID: String, file: String, hash: String) {
            self.mutationID = mutationID
            self.file = file
            self.hash = hash
        }
    }

    public let schemaVersion: Int
    public let runID: String
    public let planID: String
    public let workUnitID: String
    /// The verifier and execution implementation versions the run was
    /// produced under. A reader re-judges under the *current* verifier and
    /// reports any difference; it never adopts the recorded one.
    public let verifierVersion: Int
    public let executionVersion: Int
    /// The confirmation policy the run's verdicts were judged against.
    public let policy: MutationVerdictVerifier.VerdictVerificationPolicy
    public let entries: [Entry]

    public init(
        runID: String, planID: String, workUnitID: String, policy: MutationVerdictVerifier.VerdictVerificationPolicy,
        entries: [Entry]
    ) {
        schemaVersion = SchemaVersion.evidenceArchive
        self.runID = runID
        self.planID = planID
        self.workUnitID = workUnitID
        verifierVersion = MutationVerdictVerifier.currentVersion
        executionVersion = ExecutionImplementationVersion.current
        self.policy = policy
        self.entries = entries.sorted { $0.mutationID < $1.mutationID }
    }
}

/// One observation file: the raw observations for one mutation, bound to the
/// run and plan they came from.
public struct EvidenceArchiveEntry: Codable, Sendable {
    public let schemaVersion: Int
    public let runID: String
    public let planID: String
    public let mutationID: String
    public let observations: MutationObservations

    public init(runID: String, planID: String, observations: MutationObservations) {
        schemaVersion = SchemaVersion.evidenceArchive
        self.runID = runID
        self.planID = planID
        mutationID = observations.plannedMutation.mutationID.rawValue
        self.observations = observations
    }
}

/// The one place the archive's on-disk bytes and names are defined, so the
/// writer (execution) and the reader (verification) cannot drift apart.
public enum EvidenceArchiveCodec {
    public static let manifestFileName = "manifest.json"
    public static let observationsDirectoryName = "observations"
    /// Where archives live, relative to the project root.
    public static let relativeRoot = ".mutantkit/evidence"

    /// Whether `runID` is safe to use as a single directory name under
    /// `relativeRoot`: UUID-like (letters, digits and hyphens, 1 to 64 long),
    /// so no separator, `.` or `..` can redirect where an archive is looked
    /// for or written. Both the writer and the reader apply it.
    public static func isValidRunID(_ runID: String) -> Bool {
        guard (1 ... 64).contains(runID.utf8.count) else { return false }
        return runID.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || byte == 45
        }
    }

    public static func fileName(forMutationID id: String) -> String {
        ContentHash.shortDigest(of: id, length: 32) + ".json"
    }

    public static func encode(_ entry: EvidenceArchiveEntry) throws -> Data {
        try encoder().encode(entry)
    }

    public static func encode(_ manifest: EvidenceArchiveManifest) throws -> Data {
        try encoder().encode(manifest)
    }

    static func decodeEntry(_ data: Data) throws -> EvidenceArchiveEntry {
        try MutationPlan.decoder().decode(EvidenceArchiveEntry.self, from: data)
    }

    static func decodeManifest(_ data: Data) throws -> EvidenceArchiveManifest {
        try MutationPlan.decoder().decode(EvidenceArchiveManifest.self, from: data)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
