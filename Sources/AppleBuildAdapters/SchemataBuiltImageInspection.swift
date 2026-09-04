import Foundation
import MutationModel

/// Every way `SchemataBuiltImageInspection.inspect` refuses to produce a
/// result — fail-closed, matching `MachOReceiptExtractor`'s own discipline:
/// no image found, or a found image that could not be inspected, both throw
/// rather than returning an empty or partial result a caller could mistake
/// for "nothing to prove" instead of "inspection failed."
public enum SchemataBuiltImageInspectionError: Error, CustomStringConvertible, Equatable {
    case noImagesFound(directory: String)
    case inspectionFailed(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .noImagesFound(directory):
            "no test bundle or built binary was found under \(directory)"
        case let .inspectionFailed(path, underlying):
            "could not inspect the Mach-O image at \(path): \(underlying)"
        }
    }
}

/// One real built bundle/binary this machine actually found and extracted
/// a real `LC_UUID`-backed identity from — carries only what was physically
/// observed (a raw bundle name, a binary path, real slices). Deliberately
/// has no notion of which `BuildTargetIdentity` it belongs to: assigning
/// that is a build-system-specific decision (SwiftPM dependency-graph
/// reachability, Xcode per-target build settings) that only the adapter
/// resolving it can make correctly — this type exists purely to answer
/// "what did I find on disk," never "whose code is this."
public struct DiscoveredImage: Sendable, Equatable {
    public let bundleName: String
    public let binaryPath: String
    public let contentHash: SHA256Digest
    public let slices: [BuiltImageSlice]

    public init(bundleName: String, binaryPath: String, contentHash: SHA256Digest, slices: [BuiltImageSlice]) {
        self.bundleName = bundleName
        self.binaryPath = binaryPath
        self.contentHash = contentHash
        self.slices = slices
    }
}

/// Finds every real built bundle/binary under a schemata chunk's
/// `productsDirectory` and extracts each one's real `LC_UUID`-backed
/// identity via `MachOReceiptExtractor` — the raw discovery step every
/// build-system-specific compilation-unit-to-image resolver builds on.
///
/// A separate, self-contained bundle discovery from `TestProductHasher`'s
/// own (`Sources/AppleBuildAdapters/AdapterSupport.swift`) — that type
/// exists to answer "has the mutated code changed," a semantic-section
/// hash deliberately excluding `LC_UUID` and other path-dependent bytes;
/// this one exists to answer "what is this specific built image's real
/// identity," which needs exactly the field `TestProductHasher` excludes.
/// Reusing its private discovery internals would couple two types with
/// different, independently-evolving correctness requirements.
public enum SchemataBuiltImageInspection {
    /// Bundle kinds whose binary can carry the mutated code — same set
    /// `TestProductHasher` uses, for the same reason (a SwiftPM package
    /// statically links the module under test into its test bundle, so the
    /// image identity lives there).
    private static let bundleExtensions: Set<String> = ["xctest", "framework", "app", "appex", "bundle"]

    public static func inspect(
        productsDirectory: URL, extractor: any BuiltImageInspecting = MachOReceiptExtractor()
    ) throws -> [DiscoveredImage] {
        let bundles = discoverBundles(in: productsDirectory)
        guard !bundles.isEmpty else {
            throw SchemataBuiltImageInspectionError.noImagesFound(directory: productsDirectory.path)
        }

        var discovered: [DiscoveredImage] = []
        for bundle in bundles {
            guard let binary = executableBinary(inBundle: bundle) else { continue }
            let inspected: InspectedMachOImage
            do {
                inspected = try extractor.inspectImage(at: binary)
            } catch {
                throw SchemataBuiltImageInspectionError.inspectionFailed(path: binary.path, underlying: String(describing: error))
            }

            let slices = inspected.slices.map {
                BuiltImageSlice(
                    architecture: BuiltArchitectureIdentity(cpuType: $0.architecture.cpuType, cpuSubtype: $0.architecture.cpuSubtype),
                    imageUUID: $0.imageUUID
                )
            }
            discovered.append(
                DiscoveredImage(
                    bundleName: bundle.deletingPathExtension().lastPathComponent,
                    binaryPath: binary.path,
                    contentHash: inspected.contentHash,
                    slices: slices
                )
            )
        }

        guard !discovered.isEmpty else {
            throw SchemataBuiltImageInspectionError.noImagesFound(directory: productsDirectory.path)
        }
        return discovered
    }

    /// Inspects one specific, already-known binary path directly — no
    /// discovery, no guessing among candidates. Used by resolvers (Xcode's)
    /// that can compute the exact expected path for a target from the
    /// build system's own metadata, where "search the products directory"
    /// would be a needless reintroduction of ambiguity.
    public static func inspectSingle(
        at binaryPath: URL, bundleName: String, extractor: any BuiltImageInspecting = MachOReceiptExtractor()
    ) throws -> DiscoveredImage {
        let inspected: InspectedMachOImage
        do {
            inspected = try extractor.inspectImage(at: binaryPath)
        } catch {
            throw SchemataBuiltImageInspectionError.inspectionFailed(path: binaryPath.path, underlying: String(describing: error))
        }
        let slices = inspected.slices.map {
            BuiltImageSlice(
                architecture: BuiltArchitectureIdentity(cpuType: $0.architecture.cpuType, cpuSubtype: $0.architecture.cpuSubtype),
                imageUUID: $0.imageUUID
            )
        }
        return DiscoveredImage(bundleName: bundleName, binaryPath: binaryPath.path, contentHash: inspected.contentHash, slices: slices)
    }

    /// Sorted by path so directory-enumeration order — not stable across
    /// machines — can never change which bundle a caller treats as "the"
    /// single image in the common (one test target) case.
    private static func discoverBundles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator where bundleExtensions.contains(url.pathExtension) {
            found.append(url)
            // Nested bundles are reached through their container's own
            // binary; descending would inspect the same Mach-O twice under
            // two names.
            enumerator.skipDescendants()
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func executableBinary(inBundle bundle: URL) -> URL? {
        let name = bundle.deletingPathExtension().lastPathComponent
        let candidates = [
            bundle.appendingPathComponent("Contents/MacOS/\(name)"),
            bundle.appendingPathComponent(name)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
