
/// A CPU type/subtype pair, persisted independently of
/// `AppleBuildAdapters.ArchitectureIdentity` (a `MutationModel`-layer type
/// cannot depend on the adapter that produces it — `MutationModel` has no
/// dependencies at all). The adapter layer converts its own
/// `ArchitectureIdentity` into one of these at the one boundary where a real
/// `InspectedMachOImage` becomes a persisted `BuiltImageReceipt`.
public struct BuiltArchitectureIdentity: Codable, Sendable, Hashable {
    public let cpuType: Int32
    public let cpuSubtype: Int32

    public init(cpuType: Int32, cpuSubtype: Int32) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
    }

    private static let arm64: Int32 = 0x0100_000C
    private static let x8664: Int32 = 0x0100_0007

    /// The conventional architecture name, matching
    /// `AppleBuildAdapters.ArchitectureIdentity.description` exactly — the
    /// two types must never disagree on what a given cpuType/cpuSubtype
    /// pair is called.
    public var displayName: String {
        switch cpuType {
        case Self.arm64: "arm64"
        case Self.x8664: "x86_64"
        default: "cpu_\(String(UInt32(bitPattern: cpuType), radix: 16))_sub_\(String(UInt32(bitPattern: cpuSubtype), radix: 16))"
        }
    }
}

/// One architecture slice of one built Mach-O image — its own `LC_UUID`,
/// never averaged or collapsed with a sibling slice's. See
/// `AppleBuildAdapters.MachOSliceReceipt`'s doc comment for why a universal
/// binary's slices must stay independent.
public struct BuiltImageSlice: Codable, Sendable, Hashable {
    public let architecture: BuiltArchitectureIdentity
    public let imageUUID: ImageUUID

    public init(architecture: BuiltArchitectureIdentity, imageUUID: ImageUUID) {
        self.architecture = architecture
        self.imageUUID = imageUUID
    }
}

/// A build target's real, exact identity — never a display name compared by
/// substring or naming convention. `projectIdentity` disambiguates two
/// projects (or two packages in one workspace) that happen to name a target
/// identically, the same role it already plays on `SchemataChunk`/
/// `SchemataPlanEntry`.
///
/// Two `BuildTargetIdentity` values are equal only when every field
/// matches exactly — the type this whole redesign exists to replace was a
/// bare `String` compared by `.contains(...)`, which is exactly the kind of
/// heuristic ADR-0006 Finding 2/4 exists to eliminate. A caller that only
/// has a display name to work with (a discovered bundle's own filename, a
/// human-facing label) must resolve it to a real `BuildTargetIdentity`
/// through the build system's own metadata — `swift package describe`,
/// `xcodebuild -showBuildSettings` — never by pattern-matching the name
/// itself against another name.
public struct BuildTargetIdentity: Codable, Sendable, Hashable {
    public let projectIdentity: String
    public let targetName: String
    public let moduleName: String

    public init(projectIdentity: String, targetName: String, moduleName: String) {
        self.projectIdentity = projectIdentity
        self.targetName = targetName
        self.moduleName = moduleName
    }
}

/// What a `SchemataBuildReceipt` or `BuiltImageReceipt` construction refused,
/// and why. Every case is a fail-closed refusal: a build receipt whose own
/// identity data is already internally inconsistent must never reach the
/// verifier, which has no way to know a build-time invariant was violated
/// before it ever saw the receipt.
public enum SchemataBuildReceiptError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Two slices of the *same* built image reported the same `ImageUUID` —
    /// each architecture slice of a real Mach-O carries its own independent
    /// `LC_UUID`; two slices sharing one is a build tool malfunction, not
    /// something safe to persist and let a later verification stage
    /// discover by accident.
    case duplicateImageUUIDWithinImage(ImageUUID)
    /// Two different `CompilationUnitID`s in the same receipt claimed the
    /// same `ImageUUID`, or the same `CompilationUnitID` was reported more
    /// than once — either would make the verifier's later "unique
    /// compilation unit for this ID" lookup ambiguous.
    case duplicateCompilationUnitID(CompilationUnitID)
    /// Two different `BuiltImageReceipt`s in the same `SchemataBuildReceipt`
    /// reported the identical `BuildTargetIdentity` — a build receipt must
    /// have at most one built image per real target, or a later lookup by
    /// target identity would be ambiguous by construction.
    case duplicateBuildTarget(BuildTargetIdentity)

    public var description: String {
        switch self {
        case let .duplicateImageUUIDWithinImage(uuid):
            "image UUID \(uuid.rawValue) was reported by more than one slice of the same built image"
        case let .duplicateCompilationUnitID(id):
            "compilation unit \(id.rawValue) was reported more than once in the same build receipt"
        case let .duplicateBuildTarget(target):
            "build target \(target.targetName) (\(target.projectIdentity)) was reported by more than one built image"
        }
    }
}

/// One target's built Mach-O artifact — every architecture slice it
/// contains, each with its own proven `LC_UUID` (via
/// `AppleBuildAdapters.MachOReceiptExtractor`, not a build-tool-reported
/// placeholder). Identified by the real `BuildTargetIdentity` the build
/// system itself resolved it from — never a display/bundle name a caller
/// would otherwise have to guess at.
public struct BuiltImageReceipt: Codable, Sendable, Hashable {
    public let buildTarget: BuildTargetIdentity
    public let binaryPath: String
    public let contentHash: SHA256Digest
    public let slices: [BuiltImageSlice]

    /// - Throws: `SchemataBuildReceiptError.duplicateImageUUIDWithinImage`
    ///   if two slices of this same image report the same `ImageUUID` — a
    ///   real universal binary's arm64/x86_64 slices are independently
    ///   built and never legitimately share one.
    public init(buildTarget: BuildTargetIdentity, binaryPath: String, contentHash: SHA256Digest, slices: [BuiltImageSlice]) throws {
        var seenUUIDs: Set<ImageUUID> = []
        for slice in slices {
            guard seenUUIDs.insert(slice.imageUUID).inserted else {
                throw SchemataBuildReceiptError.duplicateImageUUIDWithinImage(slice.imageUUID)
            }
        }
        self.buildTarget = buildTarget
        self.binaryPath = binaryPath
        self.contentHash = contentHash
        // Sorted so lipo/build-tool slice ordering can never change this
        // receipt's own serialized form or hash.
        self.slices = slices.sorted { $0.architecture.cpuType < $1.architecture.cpuType }
    }
}

/// Maps one compilation unit (a source file lowered into a specific target)
/// to the real `BuildTargetIdentity` whose built image it must appear in —
/// the build-time half of ADR-0006 Finding 4/Finding 2's fix. Deliberately
/// carries no `ImageUUID` of its own: the verifier looks up the unique
/// `BuiltImageReceipt` in the same `SchemataBuildReceipt` whose
/// `buildTarget` matches exactly, and trusts *that* receipt's real,
/// independently-extracted slices — never a UUID this type would otherwise
/// have to assert on its own say-so.
public struct CompilationUnitReceipt: Codable, Sendable, Hashable {
    public let compilationUnitID: CompilationUnitID
    public let sourceEmbeddingID: SHA256Digest
    public let buildTarget: BuildTargetIdentity

    public init(compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest, buildTarget: BuildTargetIdentity) {
        self.compilationUnitID = compilationUnitID
        self.sourceEmbeddingID = sourceEmbeddingID
        self.buildTarget = buildTarget
    }
}

/// Everything one schemata chunk's build produced, in a form the verifier
/// can check a runtime observation against — the build-time counterpart to
/// `RuntimeTranscript`. Persisted alongside a checkpoint/cache entry
/// exactly like any other observation: untrusted data the verifier
/// re-checks, never assumed correct because it was written by this run's
/// own build step.
public struct SchemataBuildReceipt: Codable, Sendable, Hashable {
    public static let currentVersion = 2

    public let version: Int
    public let planID: String
    public let workUnitID: String
    public let chunkID: String
    public let toolchainHash: SHA256Digest
    public let buildArgumentsHash: SHA256Digest
    public let runtimeABIVersion: UInt32
    public let images: [BuiltImageReceipt]
    public let compilationUnits: [CompilationUnitReceipt]

    /// - Throws: `SchemataBuildReceiptError.duplicateCompilationUnitID` if
    ///   `compilationUnits` reports the same `CompilationUnitID` more than
    ///   once, or `.duplicateBuildTarget` if `images` reports the same
    ///   `BuildTargetIdentity` more than once — both would make the
    ///   verifier's chain-selection step ambiguous by construction.
    public init(
        planID: String, workUnitID: String, chunkID: String, toolchainHash: SHA256Digest,
        buildArgumentsHash: SHA256Digest, runtimeABIVersion: UInt32, images: [BuiltImageReceipt],
        compilationUnits: [CompilationUnitReceipt]
    ) throws {
        var seenUnits: Set<CompilationUnitID> = []
        for unit in compilationUnits {
            guard seenUnits.insert(unit.compilationUnitID).inserted else {
                throw SchemataBuildReceiptError.duplicateCompilationUnitID(unit.compilationUnitID)
            }
        }
        var seenTargets: Set<BuildTargetIdentity> = []
        for image in images {
            guard seenTargets.insert(image.buildTarget).inserted else {
                throw SchemataBuildReceiptError.duplicateBuildTarget(image.buildTarget)
            }
        }
        version = Self.currentVersion
        self.planID = planID
        self.workUnitID = workUnitID
        self.chunkID = chunkID
        self.toolchainHash = toolchainHash
        self.buildArgumentsHash = buildArgumentsHash
        self.runtimeABIVersion = runtimeABIVersion
        // Sorted so build-parallelism ordering can never change this
        // receipt's own serialized form or hash.
        self.images = images.sorted {
            $0.buildTarget != $1.buildTarget
                ? ($0.buildTarget.projectIdentity, $0.buildTarget.targetName)
                < ($1.buildTarget.projectIdentity, $1.buildTarget.targetName)
                : $0.binaryPath < $1.binaryPath
        }
        self.compilationUnits = compilationUnits.sorted { $0.compilationUnitID.rawValue < $1.compilationUnitID.rawValue }
    }

    /// The unique built image for `target`, or `nil` if none (or more than
    /// one — refused at construction, so "more than one" cannot actually
    /// occur here, but the lookup stays a genuine search rather than an
    /// assumption).
    public func image(for target: BuildTargetIdentity) -> BuiltImageReceipt? {
        let matches = images.filter { $0.buildTarget == target }
        return matches.count == 1 ? matches.first : nil
    }

    /// The unique compilation unit for `id`, or `nil` if none.
    public func compilationUnit(for id: CompilationUnitID) -> CompilationUnitReceipt? {
        let matches = compilationUnits.filter { $0.compilationUnitID == id }
        return matches.count == 1 ? matches.first : nil
    }
}
