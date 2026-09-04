
/// Every way the SwiftPM path refuses to map a compilation unit's target to
/// a real built image — fail-closed: an ambiguous or unproven mapping must
/// never be resolved by guessing.
public enum SwiftPMImageResolutionError: Error, CustomStringConvertible, Equatable {
    /// No test target in the dependency graph transitively depends on this
    /// target — its code was never linked into anything actually tested,
    /// so no image could ever be proven to contain it.
    case targetUnreachableFromAnyTestTarget(String)
    /// More than one built image was discovered, and none of them exactly
    /// matches a declared SwiftPM product containing this target — the
    /// common (single combined test bundle) case does not need this at
    /// all; this only triggers for a genuinely ambiguous multi-image build
    /// this resolver refuses to guess through.
    case ambiguousImageForTarget(String)

    public var description: String {
        switch self {
        case let .targetUnreachableFromAnyTestTarget(target):
            "target \(target) is not a dependency of any test target, so no built image could ever contain its code"
        case let .ambiguousImageForTarget(target):
            "more than one built image was discovered and none exactly matches a declared product containing target \(target)"
        }
    }
}

/// Maps a SwiftPM compilation unit's real target identity to the real
/// built image its code ends up in — by dependency-graph reachability
/// proven from `swift package describe`, never by matching a discovered
/// bundle's filename against the target's name.
///
/// The key fact this relies on: modern SwiftPM (`swift build --build-tests`)
/// links every local test target's own dependency closure into one
/// combined `<Package>PackageTests.xctest` bundle — confirmed against a
/// real build, not assumed. So for the ordinary case (exactly one
/// discovered image), any target reachable from at least one test target
/// is proven, by SwiftPM's own static-linking model, to be inside that one
/// image — no name comparison needed at all. A build producing more than
/// one image (a declared library/executable product built alongside the
/// test bundle) is disambiguated by exact product-name equality against
/// `swift package describe`'s own `products` list, never a substring
/// guess.
public enum SwiftPMCompilationUnitImageResolver {
    public static func resolve(
        targets: Set<String>, graph: SwiftPMDependencyGraph, discovered: [DiscoveredImage]
    ) throws -> [String: DiscoveredImage] {
        var resolved: [String: DiscoveredImage] = [:]
        for target in targets {
            resolved[target] = try resolveOne(target: target, graph: graph, discovered: discovered)
        }
        return resolved
    }

    private static func resolveOne(target: String, graph: SwiftPMDependencyGraph, discovered: [DiscoveredImage]) throws -> DiscoveredImage {
        let dependents = graph.transitiveDependents(of: target)
        guard dependents.contains(where: { graph.isTestTarget($0) }) else {
            throw SwiftPMImageResolutionError.targetUnreachableFromAnyTestTarget(target)
        }

        if discovered.count == 1 {
            // Proven by SwiftPM's own static-linking model: the target is
            // reachable from a real test target, and there is exactly one
            // built test image for this workspace to have landed in.
            return discovered[0]
        }

        // More than one image: only an exact product-name match, never a
        // substring guess, resolves the ambiguity.
        let matchingProducts = graph.products.filter { _, members in members.contains(target) }
        let candidates = discovered.filter { image in matchingProducts.keys.contains(image.bundleName) }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw SwiftPMImageResolutionError.ambiguousImageForTarget(target)
        }
        return candidate
    }
}
