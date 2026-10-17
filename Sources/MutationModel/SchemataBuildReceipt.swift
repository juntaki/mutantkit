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
/// heuristic the image-identity proof and the unit-to-image mapping exists to eliminate. A caller that only
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
    /// Two images in one receipt computed the same `BuiltImageID` — the same
    /// binary path, content hash and slices reported twice.
    case duplicateImageID(BuiltImageID)
    /// The same `ImageUUID` appears in more than one image of one receipt. A
    /// runtime observation carrying that UUID could then not be attributed to
    /// a single image, so the receipt is refused rather than left ambiguous.
    case imageUUIDSharedAcrossImages(ImageUUID)
    /// A compilation unit names a containing image that is not in the receipt.
    case unknownContainingImage(CompilationUnitID, BuiltImageID)
    /// A compilation unit lists the same containing image more than once.
    case duplicateContainingImage(CompilationUnitID, BuiltImageID)

    public var description: String {
        switch self {
        case let .duplicateImageUUIDWithinImage(uuid):
            "image UUID \(uuid.rawValue) was reported by more than one slice of the same built image"
        case let .duplicateCompilationUnitID(id):
            "compilation unit \(id.rawValue) was reported more than once in the same build receipt"
        case let .duplicateBuildTarget(target):
            "build target \(target.targetName) (\(target.projectIdentity)) was reported by more than one built image"
        case let .duplicateImageID(id):
            "built image \(id.rawValue.rawValue) was reported more than once in the same build receipt"
        case let .imageUUIDSharedAcrossImages(uuid):
            "image UUID \(uuid.rawValue) belongs to more than one built image in the same build receipt"
        case let .unknownContainingImage(unit, id):
            "compilation unit \(unit.rawValue) names containing image \(id.rawValue.rawValue), which is not in the build receipt"
        case let .duplicateContainingImage(unit, id):
            "compilation unit \(unit.rawValue) lists containing image \(id.rawValue.rawValue) more than once"
        }
    }
}

/// A built image's identity within one `SchemataBuildReceipt`: a digest of the
/// canonicalized `binaryPath`, `contentHash` and sorted `(architecture,
/// ImageUUID)` slices. Deliberately not a `BuildTargetIdentity`: a real image
/// (a combined SwiftPM test bundle, or one `.xctest` per test target that all
/// statically link the same library) need not correspond to exactly one build
/// target, and the receipt must be able to say "this unit's code is in these
/// images" without pretending otherwise (the multi-image build receipt).
public struct BuiltImageID: Codable, Sendable, Hashable {
    public let rawValue: SHA256Digest

    public init(rawValue: SHA256Digest) {
        self.rawValue = rawValue
    }

    static func derive(binaryPath: String, contentHash: SHA256Digest, slices: [BuiltImageSlice]) -> BuiltImageID {
        let sliceLines = slices
            .map { "\($0.architecture.cpuType):\($0.architecture.cpuSubtype):\($0.imageUUID.rawValue)" }
            .sorted()
        let canonical = (["v1", binaryPath, contentHash.rawValue] + sliceLines).joined(separator: "\n")
        return BuiltImageID(rawValue: SHA256Digest.of(canonical))
    }
}

/// One built Mach-O artifact — every architecture slice it contains, each
/// with its own proven `LC_UUID` (via `AppleBuildAdapters.MachOReceiptExtractor`,
/// not a build-tool-reported placeholder). Identified by `imageID`; the
/// `ownerBuildTarget` is the real `BuildTargetIdentity` the build system
/// resolved it from when there is exactly one (an Xcode target's product, a
/// SwiftPM test bundle) and is only informative: which units an image
/// contains is stated by `CompilationUnitReceipt.containingImageIDs`.
public struct BuiltImageReceipt: Codable, Sendable, Hashable {
    public let imageID: BuiltImageID
    public let ownerBuildTarget: BuildTargetIdentity?
    public let binaryPath: String
    public let contentHash: SHA256Digest
    public let slices: [BuiltImageSlice]

    /// - Throws: `SchemataBuildReceiptError.duplicateImageUUIDWithinImage`
    ///   if two slices of this same image report the same `ImageUUID` — a
    ///   real universal binary's arm64/x86_64 slices are independently
    ///   built and never legitimately share one.
    public init(ownerBuildTarget: BuildTargetIdentity?, binaryPath: String, contentHash: SHA256Digest, slices: [BuiltImageSlice]) throws {
        var seenUUIDs: Set<ImageUUID> = []
        for slice in slices {
            guard seenUUIDs.insert(slice.imageUUID).inserted else {
                throw SchemataBuildReceiptError.duplicateImageUUIDWithinImage(slice.imageUUID)
            }
        }
        // Sorted so lipo/build-tool slice ordering can never change this
        // receipt's own serialized form or hash.
        let sorted = slices.sorted { $0.architecture.cpuType < $1.architecture.cpuType }
        self.ownerBuildTarget = ownerBuildTarget
        self.binaryPath = binaryPath
        self.contentHash = contentHash
        self.slices = sorted
        self.imageID = BuiltImageID.derive(binaryPath: binaryPath, contentHash: contentHash, slices: sorted)
    }

    private enum CodingKeys: String, CodingKey {
        case imageID, ownerBuildTarget, binaryPath, contentHash, slices
    }

    /// Decoded identity is re-derived and compared, never taken as stored: a
    /// receipt whose `imageID` does not match its own path, hash and slices is
    /// refused rather than verified against an identity nothing backs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ownerBuildTarget: try container.decodeIfPresent(BuildTargetIdentity.self, forKey: .ownerBuildTarget),
            binaryPath: try container.decode(String.self, forKey: .binaryPath),
            contentHash: try container.decode(SHA256Digest.self, forKey: .contentHash),
            slices: try container.decode([BuiltImageSlice].self, forKey: .slices)
        )
        let stored = try container.decode(BuiltImageID.self, forKey: .imageID)
        guard stored == imageID else {
            throw DecodingError.dataCorruptedError(
                forKey: .imageID, in: container, debugDescription: "stored imageID does not match the image's own path, hash and slices"
            )
        }
    }

    /// The one-image-per-target shape every v2 receipt had: `buildTarget` is
    /// the image's owner.
    public init(buildTarget: BuildTargetIdentity, binaryPath: String, contentHash: SHA256Digest, slices: [BuiltImageSlice]) throws {
        try self.init(ownerBuildTarget: buildTarget, binaryPath: binaryPath, contentHash: contentHash, slices: slices)
    }
}

/// Maps one compilation unit (a source file lowered into a specific target)
/// to the built images its code is proven to be linked into — the build-time
/// half of the image-identity proof, covering many images per unit.
/// Deliberately carries no `ImageUUID` of its own: the verifier looks
/// up the `BuiltImageReceipt`s in the same `SchemataBuildReceipt` whose
/// `imageID` is listed and trusts *those* receipts' real, independently
/// extracted slices — never a UUID this type would otherwise have to assert
/// on its own say-so.
///
/// `containingImageIDs` empty means "no image proven": the verifier refuses.
/// `SchemataBuildReceipt` resolves the legacy single-image form (a unit built
/// with only its `buildTarget`) to the image owned by that target.
public struct CompilationUnitReceipt: Codable, Sendable, Hashable {
    public let compilationUnitID: CompilationUnitID
    public let sourceEmbeddingID: SHA256Digest
    public let sourceBuildTarget: BuildTargetIdentity
    public let containingImageIDs: [BuiltImageID]

    public init(
        compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest,
        sourceBuildTarget: BuildTargetIdentity, containingImageIDs: [BuiltImageID]
    ) {
        self.compilationUnitID = compilationUnitID
        self.sourceEmbeddingID = sourceEmbeddingID
        self.sourceBuildTarget = sourceBuildTarget
        self.containingImageIDs = containingImageIDs.sorted { $0.rawValue.rawValue < $1.rawValue.rawValue }
    }

    /// Legacy single-image form: the containing image is the one owned by
    /// `buildTarget`, resolved when the unit is placed in a `SchemataBuildReceipt`.
    public init(compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest, buildTarget: BuildTargetIdentity) {
        self.init(
            compilationUnitID: compilationUnitID, sourceEmbeddingID: sourceEmbeddingID,
            sourceBuildTarget: buildTarget, containingImageIDs: []
        )
    }

    /// Kept so existing call sites reading the source target keep compiling.
    public var buildTarget: BuildTargetIdentity { sourceBuildTarget }
}

/// Everything one schemata chunk's build produced, in a form the verifier
/// can check a runtime observation against — the build-time counterpart to
/// `RuntimeTranscript`. Persisted alongside a checkpoint/cache entry
/// exactly like any other observation: untrusted data the verifier
/// re-checks, never assumed correct because it was written by this run's
/// own build step.
public struct SchemataBuildReceipt: Codable, Sendable, Hashable {
    /// 3: a compilation unit names the set of images containing its code
    /// (`containingImageIDs`) and images carry an explicit `imageID` (the multi-image build receipt).
    /// 2: one `buildTarget` per unit, one image per target; still decoded,
    /// and normalized to the v3 shape.
    public static let currentVersion = 3

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
    ///   once; `.duplicateBuildTarget` if two images claim the same owner
    ///   target; `.duplicateImageID` / `.imageUUIDSharedAcrossImages` if image
    ///   identity is not unique; `.unknownContainingImage` /
    ///   `.duplicateContainingImage` if a unit's image list is inconsistent
    ///   with `images` — each would make the verifier's chain selection
    ///   ambiguous or unprovable by construction.
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
        let seenImageIDs = try Self.validatedImageIDs(images)

        let imageIDsByOwner = Dictionary(
            images.compactMap { image in image.ownerBuildTarget.map { ($0, image.imageID) } },
            uniquingKeysWith: { first, _ in first }
        )
        let resolvedUnits = try compilationUnits.map { unit -> CompilationUnitReceipt in
            if unit.containingImageIDs.isEmpty {
                // Legacy single-image form: the image owned by the unit's own build target, if any.
                guard let owned = imageIDsByOwner[unit.sourceBuildTarget] else { return unit }
                return CompilationUnitReceipt(
                    compilationUnitID: unit.compilationUnitID, sourceEmbeddingID: unit.sourceEmbeddingID,
                    sourceBuildTarget: unit.sourceBuildTarget, containingImageIDs: [owned]
                )
            }
            var seen: Set<BuiltImageID> = []
            for id in unit.containingImageIDs {
                guard seen.insert(id).inserted else {
                    throw SchemataBuildReceiptError.duplicateContainingImage(unit.compilationUnitID, id)
                }
                guard seenImageIDs.contains(id) else {
                    throw SchemataBuildReceiptError.unknownContainingImage(unit.compilationUnitID, id)
                }
            }
            return unit
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
        self.images = images.sorted(by: Self.imageSortsBefore)
        self.compilationUnits = resolvedUnits.sorted { $0.compilationUnitID.rawValue < $1.compilationUnitID.rawValue }
    }

    private static func imageSortsBefore(_ lhs: BuiltImageReceipt, _ rhs: BuiltImageReceipt) -> Bool {
        let lhsKey = (
            lhs.ownerBuildTarget?.projectIdentity ?? "", lhs.ownerBuildTarget?.targetName ?? "",
            lhs.binaryPath, lhs.imageID.rawValue.rawValue
        )
        let rhsKey = (
            rhs.ownerBuildTarget?.projectIdentity ?? "", rhs.ownerBuildTarget?.targetName ?? "",
            rhs.binaryPath, rhs.imageID.rawValue.rawValue
        )
        return lhsKey < rhsKey
    }

    private static func validatedImageIDs(_ images: [BuiltImageReceipt]) throws -> Set<BuiltImageID> {
        var seenOwners: Set<BuildTargetIdentity> = []
        var seenImageIDs: Set<BuiltImageID> = []
        var imageIDByUUID: [ImageUUID: BuiltImageID] = [:]
        for image in images {
            if let owner = image.ownerBuildTarget {
                guard seenOwners.insert(owner).inserted else {
                    throw SchemataBuildReceiptError.duplicateBuildTarget(owner)
                }
            }
            guard seenImageIDs.insert(image.imageID).inserted else {
                throw SchemataBuildReceiptError.duplicateImageID(image.imageID)
            }
            for slice in image.slices {
                if let existing = imageIDByUUID[slice.imageUUID], existing != image.imageID {
                    throw SchemataBuildReceiptError.imageUUIDSharedAcrossImages(slice.imageUUID)
                }
                imageIDByUUID[slice.imageUUID] = image.imageID
            }
        }
        return seenImageIDs
    }

    private enum CodingKeys: String, CodingKey {
        case version, planID, workUnitID, chunkID, toolchainHash, buildArgumentsHash, runtimeABIVersion, images, compilationUnits
    }

    private struct LegacyImage: Decodable {
        let buildTarget: BuildTargetIdentity
        let binaryPath: String
        let contentHash: SHA256Digest
        let slices: [BuiltImageSlice]
    }

    private struct LegacyUnit: Decodable {
        let compilationUnitID: CompilationUnitID
        let sourceEmbeddingID: SHA256Digest
        let buildTarget: BuildTargetIdentity
    }

    /// Decodes v3, and reads a v2 receipt (one `buildTarget` per unit and image)
    /// by normalizing it to the v3 shape, so evidence recorded by an older
    /// binary stays re-verifiable. The result is always re-validated by the
    /// throwing initializer above; nothing decoded is trusted as stored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        let images: [BuiltImageReceipt]
        let units: [CompilationUnitReceipt]
        switch storedVersion {
        case 2:
            images = try container.decode([LegacyImage].self, forKey: .images).map {
                try BuiltImageReceipt(
                    buildTarget: $0.buildTarget, binaryPath: $0.binaryPath, contentHash: $0.contentHash, slices: $0.slices
                )
            }
            units = try container.decode([LegacyUnit].self, forKey: .compilationUnits).map {
                CompilationUnitReceipt(
                    compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID, buildTarget: $0.buildTarget
                )
            }
        case Self.currentVersion:
            images = try container.decode([BuiltImageReceipt].self, forKey: .images)
            units = try container.decode([CompilationUnitReceipt].self, forKey: .compilationUnits)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "unsupported schemata build receipt version \(storedVersion)"
            )
        }
        try self.init(
            planID: try container.decode(String.self, forKey: .planID),
            workUnitID: try container.decode(String.self, forKey: .workUnitID),
            chunkID: try container.decode(String.self, forKey: .chunkID),
            toolchainHash: try container.decode(SHA256Digest.self, forKey: .toolchainHash),
            buildArgumentsHash: try container.decode(SHA256Digest.self, forKey: .buildArgumentsHash),
            runtimeABIVersion: try container.decode(UInt32.self, forKey: .runtimeABIVersion),
            images: images,
            compilationUnits: units
        )
    }

    /// The unique image owned by `target`, or `nil` if none (or more than
    /// one — refused at construction, so "more than one" cannot actually
    /// occur here, but the lookup stays a genuine search rather than an
    /// assumption).
    public func image(for target: BuildTargetIdentity) -> BuiltImageReceipt? {
        let matches = images.filter { $0.ownerBuildTarget == target }
        return matches.count == 1 ? matches.first : nil
    }

    /// Every image the receipt proves contains `unit`'s code, in receipt order.
    /// Empty when the unit names none, or names one this receipt does not hold
    /// (construction refuses the latter, so a stale unit cannot reach here).
    public func images(containing unit: CompilationUnitReceipt) -> [BuiltImageReceipt] {
        let wanted = Set(unit.containingImageIDs)
        return images.filter { wanted.contains($0.imageID) }
    }

    /// The unique compilation unit for `id`, or `nil` if none.
    public func compilationUnit(for id: CompilationUnitID) -> CompilationUnitReceipt? {
        let matches = compilationUnits.filter { $0.compilationUnitID == id }
        return matches.count == 1 ? matches.first : nil
    }
}
